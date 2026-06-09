provider "aws" {
  region = "us-west-2"
}

resource "aws_instance" "example" {
  ami           = "ami-0c2ab3b8efb09f272"
  instance_type = "t3.micro"
  root_block_device {
    volume_size = 100
  }
}