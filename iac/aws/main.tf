provider "aws" {
  region = "us-east-1"
}

resource "aws_instance" "example" {
  ami           = "ami-0c94855ba95c71c99"
  instance_type = "m5.xlarge"
  root_block_device {
    volume_size = 50
  }
}