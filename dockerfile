# Use an official Python runtime as the parent image
FROM python:3.11-slim

# Set the working directory in the container to /app
WORKDIR /app

# Copy the current directory contents into the container at /app
COPY requirements.txt /app

# Install required packages
RUN pip install --no-cache-dir -r requirements.txt

COPY ./data /app/data
COPY app.py /app

# Define environment variable for additional configuration
ENV PORT=8050

# Expose the port the app runs on
EXPOSE 8050

# Command to run the application
CMD ["gunicorn", "app:server", "-b", "0.0.0.0:8050", "--workers=4", "--threads=4", "--timeout=300"]
