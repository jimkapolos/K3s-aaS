FROM python:3.8-slim

WORKDIR /app

# Installing libraries
RUN pip install flask

# Copy the code to the application
COPY db.py /app/

# Create the folder for the database
RUN mkdir -p /app/data

# Opening of port 5000
EXPOSE 5000

CMD ["python", "db.py"]
