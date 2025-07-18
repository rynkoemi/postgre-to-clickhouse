FROM debezium/connect:2.5

# Create a directory inside the container
RUN mkdir -p /kafka/connect/debezium-avro-converter

# Copy files from the host to the container
COPY ./debezium-avro-converter /kafka/connect/debezium-avro-converter
