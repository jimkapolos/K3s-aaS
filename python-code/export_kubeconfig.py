import requests
import zipfile
import os
import base64
import logging
import subprocess
import shutil

# Configure logging settings
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

GITHUB_TOKEN = os.getenv("GITHUB_TOKEN")  # Retrieve GitHub token from environment variable
REPO = "APELGroup/K3s-aaS"  # Define the GitHub repository name

# Function to generate GitHub API headers
def get_github_headers():
    return {"Accept": "application/vnd.github.v3+json", "Authorization": f"token {GITHUB_TOKEN}"}

# Function to extract MASTER_IP from the artifact directory
def get_master_ip(artifact_dir):
    try:
        with open(f"{artifact_dir}/master-outputs.env") as f:
            for line in f:
                if line.startswith("MASTER_IP="):
                    return line.split("=")[1].strip()
    except FileNotFoundError:
        logging.error("MASTER_IP not found in master-outputs.env")
    return None

# Function to download and extract the GitHub Actions artifact
def download_and_extract_artifact(run_id):
    artifact_url = f"https://api.github.com/repos/{REPO}/actions/runs/{run_id}/artifacts"
    response = requests.get(f"{artifact_url}?run_id={run_id}", headers=get_github_headers())
    
    if response.status_code != 200:
        logging.error("Failed to fetch artifacts.")
        return None
    
    # Find the specific artifact named 'master-outputs'
    artifact = next((a for a in response.json().get("artifacts", []) if a["name"] == "master-outputs"), None)
    if not artifact:
        logging.error("Artifact not found.")
        return None

    artifact_id = artifact["id"]
    download_url = f"https://api.github.com/repos/{REPO}/actions/artifacts/{artifact_id}/zip"
    zip_filename = f"artifact_{run_id}_{artifact_id}.zip"
    artifact_dir = f"artifact_{run_id}_{artifact_id}"
    
    # Ensure the directory is clean before extraction
    if os.path.exists(artifact_dir): shutil.rmtree(artifact_dir)
    os.makedirs(artifact_dir, exist_ok=True)

    # Download and extract the artifact
    with open(zip_filename, "wb") as f:
        f.write(requests.get(download_url, headers=get_github_headers()).content)

    with zipfile.ZipFile(zip_filename, "r") as zip_ref:
        zip_ref.extractall(artifact_dir)
    os.remove(zip_filename)
    return artifact_dir

# Function to decode the kubeconfig file and update it with the MASTER_IP
def decode_and_update_kubeconfig(artifact_dir, run_id, master_ip):
    kubeconfig_path = f"kubeconfig_{run_id}.yaml"
    
    try:
        # Extract base64-encoded kubeconfig from the artifact
        with open(f"{artifact_dir}/kubeconfig.env") as f:
            encoded_kubeconfig = next((line.split("=")[1].strip() for line in f if line.startswith("KUBECONFIG_FILE=")), None)
        
        if not encoded_kubeconfig:
            logging.error("KUBECONFIG_FILE not found or empty.")
            return None
        
        # Ensure proper base64 padding
        missing_padding = len(encoded_kubeconfig) % 4
        if missing_padding:
            encoded_kubeconfig += "=" * (4 - missing_padding)

        decoded_kubeconfig = base64.b64decode(encoded_kubeconfig).decode("utf-8")
        
        with open(kubeconfig_path, "w") as kf:
            kf.write(decoded_kubeconfig)

        # Replace server IP and disable certificate authority validation
        with open(kubeconfig_path, "r") as f:
            content = f.read().replace("server: https://127.0.0.1:6443", f"server: https://{master_ip}:6443\n    insecure-skip-tls-verify: true")
            content = content.replace("certificate-authority-data:", "#certificate-authority-data:")

        with open(kubeconfig_path, "w") as f:
            f.write(content)

        logging.info(f"Kubeconfig updated with MASTER_IP: {master_ip}")
        return kubeconfig_path

    except Exception as e:
        logging.error(f"Error decoding kubeconfig: {e}")
        return None

# Function to execute Helm commands using the updated kubeconfig
def run_helm_commands(kubeconfig_path):
    helm_repo_name = input("Enter Helm repository name: ")
    helm_repo = input("Enter Helm repository URL: ")
    helm_chart = input("Enter Helm chart name: ")
    release_name = input("Enter Helm release name: ")
    
    commands = [
        ["helm", "repo", "add", helm_repo_name, helm_repo, "--kubeconfig", kubeconfig_path],
        ["helm", "repo", "update", "--kubeconfig", kubeconfig_path],
        ["helm", "install", release_name, helm_chart, "--kubeconfig", kubeconfig_path]
    ]
    
    # Execute each Helm command sequentially
    for cmd in commands:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            logging.error(f"Failed: {result.stderr.strip()}")
            return False
    return True

# Function to retrieve the latest workflow run ID for 'Deploy VMs Master'
def get_latest_run_id():
    runs_url = f"https://api.github.com/repos/{REPO}/actions/runs"
    response = requests.get(runs_url, headers=get_github_headers())

    if response.status_code != 200:
        logging.error("Failed to fetch workflow runs.")
        return None

    runs = response.json().get("workflow_runs", [])
    if not runs:
        logging.error("No workflow runs found.")
        return None

    # Look for the latest run with the specific workflow name
    for run in runs:
        if run["name"] == "Deploy VMs Master":
            latest_run_id = run["id"]
            logging.info(f"Latest run ID for 'Deploy VMs Master': {latest_run_id}")
            return latest_run_id

    logging.error("No runs found for 'Deploy VMs Master'.")
    return None

# Main execution function
def main():
    run_id = get_latest_run_id()
    if not run_id:
        return
    
    artifact_dir = download_and_extract_artifact(run_id)
    if not artifact_dir:
        return
    
    master_ip = get_master_ip(artifact_dir)
    if not master_ip:
        return

    kubeconfig_path = decode_and_update_kubeconfig(artifact_dir, run_id, master_ip)
    if not kubeconfig_path:
        return
    
    if run_helm_commands(kubeconfig_path):
        logging.info("Helm installation successful!")
    else:
        logging.error("Helm installation failed!")

# Execute the script if run directly
if __name__ == "__main__":
    main()
