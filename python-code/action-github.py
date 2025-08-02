import requests
import os 
import time
import logging
import sys
import export_kubeconfig  # Module for exporting Kubeconfig
import upload  # Module for uploading necessary files
from dotenv import load_dotenv

# Configure logging to log both to a file and the console
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.FileHandler("workflow_runner.log"), logging.StreamHandler()],
)

# Get GitHub token from environment variables
load_dotenv()  # Load environment variables from .env file
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN")
print(GITHUB_TOKEN)
REPO = "APELGroup/K3s-aaS"  # GitHub repository name
API_URL = f"https://api.github.com/repos/{REPO}/actions/workflows"

# Prompt user to enter the number of worker VMs to deploy
NUM_WORKERS = int(input("Enter the number of worker VMs to deploy: "))

# Headers for GitHub API requests
HEADERS = {
    "Accept": "application/vnd.github.v3+json",
    "Authorization": f"token {GITHUB_TOKEN}",
}

def get_workflow_id(workflow_name):
    """Find the ID of a workflow by its name."""
    response = requests.get(API_URL, headers=HEADERS)
    if response.status_code == 200:
        workflows = response.json().get("workflows", [])
        for wf in workflows:
            if wf["name"] == workflow_name:
                return wf["id"]
    logging.error(f"Workflow '{workflow_name}' not found.")
    return None

def trigger_workflow(workflow_id, var_file=None):
    """Trigger a workflow using its ID."""
    payload = {"ref": "main"}
    if var_file:
        payload["inputs"] = {"var_file": var_file}

    response = requests.post(
        f"{API_URL}/{workflow_id}/dispatches",
        json=payload,
        headers=HEADERS,
    )
    return response.status_code == 204  # Returns True if successful

def get_latest_run(workflow_id):
    """Retrieve the URL of the latest workflow run."""
    response = requests.get(f"{API_URL}/{workflow_id}/runs", headers=HEADERS)
    runs = response.json().get("workflow_runs", []) if response.status_code == 200 else []
    return runs[0]["url"] if runs else None  # Return the first run's URL

def check_status(url):
    """Check the status of a workflow run."""
    for _ in range(120):  # Try for up to 30 minutes (120 * 15 sec)
        response = requests.get(url, headers=HEADERS)
        if response.status_code == 200:
            status, conclusion = response.json().get("status"), response.json().get("conclusion")
            if status == "completed":
                return conclusion == "success"
        time.sleep(15)  # Wait before retrying
    return False  # Return False if it times out

def deploy_vm(workflow_name, var_file):
    """Deploy a VM using a GitHub Actions workflow."""
    workflow_id = get_workflow_id(workflow_name)
    if not workflow_id:
        return False

    if trigger_workflow(workflow_id, var_file):
        time.sleep(15)  # Wait before checking status
        return check_status(get_latest_run(workflow_id))
    return False

def deploy_helm_after_vms():
    """Deploy Helm after VM deployment is complete."""
    export_kubeconfig.main()

def upload_master():
    """Upload necessary files for the master node."""
    upload.main()

def main():
    """Main function to orchestrate VM deployment and Helm setup."""
    # Deploy the master VM first
    if not deploy_vm("Deploy VMs Master", "main.tf"):
        logging.error("Master VM deployment failed.")
        sys.exit(1)

    # Deploy worker VMs
    for i in range(NUM_WORKERS):
        if not deploy_vm("Deploy VMs Agent", f"worker-main-{i + 1}.tf"):
            logging.error(f"Worker VM {i + 1} deployment failed.")
            sys.exit(1)

    logging.info("All VMs deployed successfully.")

    # Upload necessary files
    upload_master()

    # Deploy Helm
    deploy_helm_after_vms()

    sys.exit(0)  # Exit successfully

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        logging.info("Script stopped manually by user.")
        sys.exit(2)  # Exit with a different code when interrupted
