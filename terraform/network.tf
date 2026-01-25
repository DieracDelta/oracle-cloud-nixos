# Virtual Cloud Network
resource "oci_core_vcn" "nixos" {
  compartment_id = local.compartment_id
  display_name   = "${var.network_name}-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "nixos"
}

# Internet Gateway
resource "oci_core_internet_gateway" "nixos" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.nixos.id
  display_name   = "${var.network_name}-igw"
  enabled        = true
}

# Route Table
resource "oci_core_route_table" "nixos" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.nixos.id
  display_name   = "${var.network_name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.nixos.id
  }
}

# Security List
resource "oci_core_security_list" "nixos" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.nixos.id
  display_name   = "${var.network_name}-sl"

  # Egress: allow all outbound
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # SSH
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Eternal Terminal
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 2022
      max = 2022
    }
  }

  # ICMP - Destination Unreachable (fragmentation needed)
  ingress_security_rules {
    protocol  = "1" # ICMP
    source    = "0.0.0.0/0"
    stateless = false
    icmp_options {
      type = 3
      code = 4
    }
  }

  # ICMP - Echo Request (ping)
  ingress_security_rules {
    protocol  = "1" # ICMP
    source    = "0.0.0.0/0"
    stateless = false
    icmp_options {
      type = 8
    }
  }
}

# Subnet
resource "oci_core_subnet" "nixos" {
  compartment_id             = local.compartment_id
  vcn_id                     = oci_core_vcn.nixos.id
  availability_domain        = local.availability_domain
  display_name               = "${var.network_name}-subnet"
  cidr_block                 = "10.0.1.0/24"
  route_table_id             = oci_core_route_table.nixos.id
  security_list_ids          = [oci_core_security_list.nixos.id]
  prohibit_public_ip_on_vnic = false
  dns_label                  = "subnet"
}
