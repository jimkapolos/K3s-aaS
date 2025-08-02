import requests
import os
import logging
from io import BytesIO
import zipfile
import base64

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

# GitHub credentials and repository details
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN")
REPO = "APELGroup/K3s-aaS"
WORKFLOW_NAME = "Deploy VMs Master"

def get_github_headers():
    """Returns the headers required for GitHub API requests."""
    return {"Accept": "application/vnd.github.v3+json", "Authorization": f"token {GITHUB_TOKEN}"}

def get_latest_run_id():
    """Fetches the latest workflow run ID for 'Deploy VMs Master'."""
    url = f"https://api.github.com/repos/{REPO}/actions/runs"
    response = requests.get(url, headers=get_github_headers())

    if response.status_code != 200:
        logging.error(f"Failed to fetch runs: {response.text}")
        return None

    # Iterate through the workflow runs to find the latest one with the correct name
    runs = response.json().get("workflow_runs", [])
    for run in runs:
        if run.get("name") == WORKFLOW_NAME:
            logging.info(f"Latest run ID for '{WORKFLOW_NAME}': {run['id']}")
            return run["id"]

    logging.error(f"No runs found for workflow '{WORKFLOW_NAME}'.")
    return None

def get_master_info_from_github(run_id):
    """Fetches and decodes kubeconfig and master IP from GitHub artifacts."""
    artifact_url = f"https://api.github.com/repos/{REPO}/actions/runs/{run_id}/artifacts"
    response = requests.get(artifact_url, headers=get_github_headers())

    if response.status_code != 200:
        logging.error("Failed to fetch artifacts.")
        return None, None

    # Locate the correct artifact containing the master outputs
    artifact = next((a for a in response.json().get("artifacts", []) if a["name"] == "master-outputs"), None)
    if not artifact:
        logging.error("Artifact not found.")
        return None, None

    artifact_id = artifact["id"]
    download_url = f"https://api.github.com/repos/{REPO}/actions/artifacts/{artifact_id}/zip"

    zip_response = requests.get(download_url, headers=get_github_headers())
    if zip_response.status_code != 200:
        logging.error("Failed to download artifact zip file.")
        return None, None

    master_ip = None
    kubeconfig_base64 = None

    # Extract files from the ZIP archive
    with zipfile.ZipFile(BytesIO(zip_response.content)) as zip_ref:
        file_list = zip_ref.namelist()
        logging.info(f"ZIP Contents: {file_list}")  # Debugging: List contents of the ZIP file

        # Extract master IP from 'master-outputs.env'
        if "master-outputs.env" in file_list:
            with zip_ref.open("master-outputs.env") as f:
                for line in f.read().decode().splitlines():
                    if line.startswith("MASTER_IP="):
                        master_ip = line.split("=")[1].strip()

        # Extract kubeconfig from 'kubeconfig.env'
        if "kubeconfig.env" in file_list:
            with zip_ref.open("kubeconfig.env") as f:
                for line in f.read().decode().splitlines():
                    if line.startswith("KUBECONFIG_FILE="):
                        kubeconfig_base64 = line.split("=")[1].strip()
                
                # Ensure proper Base64 padding
                missing_padding = len(kubeconfig_base64) % 4
                if missing_padding:
                    kubeconfig_base64 += "=" * (4 - missing_padding)
                
                # Validate Base64 encoding
                try:
                    base64.b64decode(kubeconfig_base64)
                except Exception as e:
                    logging.error(f"Invalid Base64 encoding: {e}")
                    kubeconfig_base64 = None

    if not master_ip:
        logging.error("MASTER_IP not found in master-outputs.env.")
    if not kubeconfig_base64:
        logging.error("KUBECONFIG_FILE not found in kubeconfig.env.")

    return master_ip, kubeconfig_base64

def upload_to_database(kubeconfig_base64, cluster_id, user_id, run_id):
    """Uploads the kubeconfig data to the database."""
    url = "http://localhost:5000/insert"
    data = {"cluster_id": cluster_id, "user_id": user_id, "kubeconfig": kubeconfig_base64, "run_id": run_id}
    response = requests.post(url, json=data)

    if response.status_code in [200, 201]:
        logging.info("Successfully uploaded kubeconfig to database.")
    else:
        logging.error(f"Failed to upload kubeconfig to database: {response.text}")

def main():
    """Main function to retrieve workflow data and upload it to the database."""
    run_id = get_latest_run_id()
    if not run_id:
        logging.error("Could not retrieve a valid run ID.")
        return

    master_ip, encoded_kubeconfig = get_master_info_from_github(run_id)

    if not master_ip or not encoded_kubeconfig:
        logging.error("Failed to retrieve required information.")
        return

    cluster_id = f"cluster_{master_ip}"
    user_id = os.getenv("GITHUB_ACTOR")

    logging.info(f"MASTER_IP: {master_ip}")
    logging.info(f"Cluster ID: {cluster_id}")
    logging.info(f"User ID: {user_id}")
    logging.info(f"RUN ID: {run_id}")

    upload_to_database(encoded_kubeconfig, cluster_id, user_id, run_id)

if __name__ == "__main__":
    main()
