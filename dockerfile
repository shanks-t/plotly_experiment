# Use an official Python runtime as the parent image
FROM python:3.11-slim

# Set the working directory in the container to /app
WORKDIR /app

# Copy the current directory contents into the container at /app
COPY requirements.txt /app

# Install required packages
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application to the image's workdir
COPY ./app /app

# Command to run the application
CMD ["gunicorn", "app:server", "-w", "4","-b", "0.0.0.0:8080" ]
