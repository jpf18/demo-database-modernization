terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
    confluent = {
      source  = "confluentinc/confluent"
      version = "1.46.0"
    }
    cloudamqp = {
      source  = "cloudamqp/cloudamqp"
      version = "1.27.0"
    }
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = "1.10.0"
    }
  }
}

provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret
}

provider "confluent" {
  # https://developer.hashicorp.com/terraform/language/providers/configuration#alias-multiple-provider-configurations
  alias = "kafka"

  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret

  #   kafka_id            = confluent_kafka_cluster.basic.id
  kafka_rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  kafka_api_key       = confluent_api_key.app-manager-kafka-api-key.id
  kafka_api_secret    = confluent_api_key.app-manager-kafka-api-key.secret
}

provider "aws" {
  region = var.region
}

# Configure the CloudAMQP Provider
provider "cloudamqp" {
  apikey = var.cloudamqp_customer_api_key
}

# Configure the MongoDB Atlas Provider 
provider "mongodbatlas" {
  public_key  = var.mongodbatlas_public_key
  private_key = var.mongodbatlas_private_key
}

resource "confluent_environment" "demo" {
  display_name = "Demo_Database_Modernization"
}

data "confluent_schema_registry_region" "essentials" {
  cloud   = "AWS"
  region  = "us-east-2"
  package = "ESSENTIALS"
}

resource "confluent_schema_registry_cluster" "essentials" {
  package = data.confluent_schema_registry_region.essentials.package

  environment {
    id = confluent_environment.demo.id
  }

  region {
    # See https://docs.confluent.io/cloud/current/stream-governance/packages.html#stream-governance-regions
    id = data.confluent_schema_registry_region.essentials.id
  }
}

resource "confluent_kafka_cluster" "basic" {
  display_name = "demo_kafka_cluster"
  availability = "SINGLE_ZONE"
  cloud        = "AWS"
  region       = "us-west-2"
  basic {}

  environment {
    id = confluent_environment.demo.id
  }
}

# 'app-manager' service account is required in this configuration to create 'rabbitmq_transactions' topic and grant ACLs
# to 'app-producer' and 'app-consumer' service accounts.
resource "confluent_service_account" "app-manager" {
  display_name = "app-manager"
  description  = "Service account to manage 'demo' Kafka cluster"
}

resource "confluent_role_binding" "app-manager-kafka-cluster-admin" {
  principal   = "User:${confluent_service_account.app-manager.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.basic.rbac_crn
}

resource "confluent_api_key" "app-manager-kafka-api-key" {
  display_name = "app-manager-kafka-api-key"
  description  = "Kafka API Key that is owned by 'app-manager' service account"
  owner {
    id          = confluent_service_account.app-manager.id
    api_version = confluent_service_account.app-manager.api_version
    kind        = confluent_service_account.app-manager.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.basic.id
    api_version = confluent_kafka_cluster.basic.api_version
    kind        = confluent_kafka_cluster.basic.kind

    environment {
      id = confluent_environment.demo.id
    }
  }

  # The goal is to ensure that confluent_role_binding.app-manager-kafka-cluster-admin is created before
  # confluent_api_key.app-manager-kafka-api-key is used to create instances of
  # confluent_kafka_topic, confluent_kafka_acl resources.

  # 'depends_on' meta-argument is specified in confluent_api_key.app-manager-kafka-api-key to avoid having
  # multiple copies of this definition in the configuration which would happen if we specify it in
  # confluent_kafka_topic, confluent_kafka_acl resources instead.
  depends_on = [
    confluent_role_binding.app-manager-kafka-cluster-admin
  ]
}

# Create rabbitmq_transactions topic 
resource "confluent_kafka_topic" "rabbitmq_transactions" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }

  topic_name       = "rabbitmq_transactions"
  rest_endpoint    = confluent_kafka_cluster.basic.rest_endpoint
  partitions_count = 1
  credentials {
    key    = confluent_api_key.app-manager-kafka-api-key.id
    secret = confluent_api_key.app-manager-kafka-api-key.secret
  }
}

# Create Oracle redo log topic 
resource "confluent_kafka_topic" "oracle_redo_log" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }

  topic_name       = "OracleCdcSourceConnector-dbmod-redo-log"
  rest_endpoint    = confluent_kafka_cluster.basic.rest_endpoint
  partitions_count = 1
  credentials {
    key    = confluent_api_key.app-manager-kafka-api-key.id
    secret = confluent_api_key.app-manager-kafka-api-key.secret
  }
}

# Create a service account for ksqlDB 
resource "confluent_service_account" "app-ksql" {
  display_name = "app-ksql"
  description  = "Service account to manage 'demo-ksql' ksqlDB cluster"
}

resource "confluent_role_binding" "app-ksql-kafka-cluster-admin" {
  principal   = "User:${confluent_service_account.app-ksql.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.basic.rbac_crn
}

resource "confluent_role_binding" "app-ksql-schema-registry-resource-owner" {
  principal   = "User:${confluent_service_account.app-ksql.id}"
  role_name   = "ResourceOwner"
  crn_pattern = format("%s/%s", confluent_schema_registry_cluster.essentials.resource_name, "subject=*")

  lifecycle {
    prevent_destroy = false
  }
}

# Create ksqlDB cluster  
resource "confluent_ksql_cluster" "demo-ksql" {
  display_name = "demo-ksql"
  csu          = 1
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  credential_identity {
    id = confluent_service_account.app-ksql.id
  }
  environment {
    id = confluent_environment.demo.id
  }
  depends_on = [
    confluent_role_binding.app-ksql-kafka-cluster-admin,
    confluent_role_binding.app-ksql-schema-registry-resource-owner,
    confluent_schema_registry_cluster.essentials
  ]
}

# Create Amazon RDS (Oracle)
resource "aws_db_instance" "db-mod-demo" {
  identifier     = var.rds_instance_identifier
  engine         = "oracle-se2"
  engine_version = "19"
  instance_class = var.rds_instance_class
  name           = "ORCL"
  username       = var.rds_username
  password       = var.rds_password
  port           = 1521
  license_model  = "license-included"
  #   parameter_group_name = "default.oracle-se2-19.0"
  allocated_storage   = 20
  storage_encrypted   = false
  skip_final_snapshot = true
  publicly_accessible = true
  tags = {
    name       = "db-mod-demo"
    created_by = "terraform"
  }
}

# Create a new cloudamqp instance
resource "cloudamqp_instance" "instance" {
  name        = "db-mod-demo"
  plan        = "lemur"
  region      = "amazon-web-services::us-west-2"
  tags        = ["terraform"]
  rmq_version = "3.12.1"
}

# To retrieve the password for the newly created instance
data "cloudamqp_credentials" "credentials" {
  instance_id = cloudamqp_instance.instance.id
}

# Create a Project
resource "mongodbatlas_project" "atlas-project" {
  org_id = var.mongodbatlas_org_id
  name   = var.mongodbatlas_project_name
}

# Create MongoDB Atlas resources
resource "mongodbatlas_cluster" "demo-database-modernization" {
  project_id = mongodbatlas_project.atlas-project.id
  name       = "demo-db-mod"

  # Provider Settings "block"
  provider_instance_size_name = "M0"
  provider_name               = "TENANT"
  backing_provider_name       = "AWS"
  provider_region_name        = var.mongodbatlas_region
}

resource "mongodbatlas_project_ip_access_list" "demo-database-modernization-ip" {
  project_id = mongodbatlas_project.atlas-project.id
  cidr_block = "0.0.0.0/0"
  comment    = "Allow connections from anywhere for demo purposes"
}

# Create a MongoDB Atlas Admin Database User
resource "mongodbatlas_database_user" "demo-database-modernization-db-user" {
  username           = var.mongodbatlas_database_username
  password           = var.mongodbatlas_database_password
  project_id         = mongodbatlas_project.atlas-project.id
  auth_database_name = "admin"

  roles {
    role_name     = "readWrite"
    database_name = mongodbatlas_cluster.demo-database-modernization.name
  }
}