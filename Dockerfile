FROM python:3.12

ENV PYTHONUNBUFFERED True

RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    jq \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Download and install AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm awscliv2.zip && \
    rm -rf aws

ENV APP_HOME /app
WORKDIR $APP_HOME
COPY ./sample-app ./

RUN pip install --no-cache-dir -r requirements.txt
CMD ["sleep", "infinity"]