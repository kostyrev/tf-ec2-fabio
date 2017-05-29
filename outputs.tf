output "address" {
  value = "${aws_elb.fabio.dns_name}"
}

output "elb_zone_id" {
  value = "${aws_elb.fabio.zone_id}"
}

// Can be used to add additional SG rules to fabio instances.
output "fabio_security_group" {
  value = "${aws_security_group.fabio.id}"
}

// Can be used to add additional SG rules to the fabio ELB.
output "elb_security_group" {
  value = "${aws_security_group.elb.id}"
}
