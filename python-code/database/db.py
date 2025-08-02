from flask import Flask, request, jsonify
import sqlite3
import os

app = Flask(__name__)

# Function to initialize the database
def init_db():
    # Create the "data" directory if it does not exist
    if not os.path.exists("data"):
        os.makedirs("data")

    # Connect to the SQLite database (or create it if it doesn't exist)
    conn = sqlite3.connect("data/db.sqlite")
    c = conn.cursor()

    # Create a table to store cluster data if it does not already exist
    c.execute(
        """CREATE TABLE IF NOT EXISTS cluster_data (
                    cluster_id TEXT PRIMARY KEY,
                    user_id TEXT,
                    kubeconfig TEXT,
                    run_id TEXT)"""
    )
    conn.commit()
    conn.close()

# Route to insert data into the database
@app.route("/insert", methods=["POST"])
def insert_data():
    # Get JSON data from the request
    data = request.json
    cluster_id = data.get("cluster_id")
    user_id = data.get("user_id")
    kubeconfig = data.get("kubeconfig")
    run_id = data.get("run_id")

    # Check if all required fields are provided
    if not cluster_id or not user_id or not kubeconfig or not run_id:
        return jsonify({"error": "Missing data"}), 400

    # Insert data into the database
    conn = sqlite3.connect("data/db.sqlite")
    c = conn.cursor()
    c.execute(
        "INSERT INTO cluster_data (cluster_id, user_id, kubeconfig, run_id) VALUES (?, ?, ?, ?)",
        (cluster_id, user_id, kubeconfig, run_id),
    )
    conn.commit()
    conn.close()

    return jsonify({"message": "Data inserted successfully"}), 201

# Route to retrieve data from the database
@app.route("/get/<cluster_id>", methods=["GET"])
def get_data(cluster_id):
    # Connect to the database
    conn = sqlite3.connect("data/db.sqlite")
    c = conn.cursor()

    # Retrieve data for the given cluster_id
    c.execute("SELECT * FROM cluster_data WHERE cluster_id = ?", (cluster_id,))
    row = c.fetchone()
    conn.close()

    # If data exists, return it; otherwise, return an error message
    if row:
        return (
            jsonify(
                {
                    "cluster_id": row[0],
                    "user_id": row[1],
                    "kubeconfig": row[2],
                    "run_id": row[3],
                }
            ),
            200,
        )
    else:
        return jsonify({"error": "Cluster not found"}), 404

# Route to delete data from the database
@app.route("/delete", methods=["DELETE"])
def delete_data():
    # Get JSON data from the request
    data = request.json
    cluster_id = data.get("cluster_id")
    run_id = data.get("run_id")

    # Check if both cluster_id and run_id are provided
    if not cluster_id or not run_id:
        return jsonify({"error": "Missing cluster_id or run_id"}), 400

    # Delete the specified record from the database
    conn = sqlite3.connect("data/db.sqlite")
    c = conn.cursor()
    c.execute("DELETE FROM cluster_data WHERE cluster_id = ? AND run_id = ?", (cluster_id, run_id))
    conn.commit()
    conn.close()

    return jsonify({"message": f"Cluster {cluster_id} with run_id {run_id} deleted successfully"}), 200

# Entry point of the application
if __name__ == "__main__":
    # Initialize the database before starting the application
    init_db()
    # Run the Flask app, accessible on all network interfaces at port 5000
    app.run(host="0.0.0.0", port=5000)
