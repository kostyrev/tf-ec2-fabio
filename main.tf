data "template_file" "fabio" {
  template = <<EOF
#cloud-config
repo_update: false
repo_upgrade: false

mounts:
  - [ swap, null ]
  - [ ephemeral0, null ]
  - [ ephemeral1, null ]

write_files:
  - path: /etc/consul/consul.json
    permissions: '0640'
    owner: consul:root
    content: |
      {"datacenter": "$${datacenter}",
       "raft_protocol": 3,
       "data_dir":  "/var/lib/consul",
       "retry_join_ec2": {
         "region": "$${datacenter}",
         "tag_key": "$${ec2_tag_key}",
         "tag_value": "$${ec2_tag_value}"
       },
       "leave_on_terminate": true,
       "performance": {"raft_multiplier": 1}}

runcmd:
   - systemctl enable consul
   - systemctl start consul
   - systemctl enable fabio
   - systemctl start fabio
EOF

  vars {
    datacenter    = "${var.datacenter}"
    ec2_tag_key   = "${var.ec2_tag_key}"
    ec2_tag_value = "${var.ec2_tag_value}"
  }
}

// We launch fabio into an ASG so that it can properly bring them up for us.
resource "aws_autoscaling_group" "fabio" {
  name_prefix               = "${format("%s-", var.name)}"
  launch_configuration      = "${aws_launch_configuration.fabio.name}"
  min_size                  = "${var.nodes}"
  max_size                  = "${var.nodes}"
  desired_capacity          = "${var.nodes}"
  health_check_grace_period = 15
  health_check_type         = "EC2"
  vpc_zone_identifier       = ["${split(",", var.subnets)}"]
  load_balancers            = ["${aws_elb.fabio.id}"]

  tag {
    key                 = "Name"
    value               = "${format("%s", var.name)}"
    propagate_at_launch = true
  }
}

resource "aws_launch_configuration" "fabio" {
  name_prefix          = "${format("%s-", var.name)}"
  image_id             = "${var.ami}"
  instance_type        = "${var.instance_type}"
  iam_instance_profile = "${var.instance_profile}"
  security_groups      = ["${aws_security_group.fabio.id}"]
  user_data            = "${data.template_file.fabio.rendered}"
}

// Security group for fabio allows SSH and HTTP access (via "tcp" in
// case TLS is used)
resource "aws_security_group" "fabio" {
  name        = "${format("%s", var.name)}"
  description = "fabio servers"
  vpc_id      = "${var.vpc-id}"
}

resource "aws_security_group_rule" "fabio-ssh" {
  security_group_id = "${aws_security_group.fabio.id}"
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

// This rule allows fabio HTTP API access to individual nodes
resource "aws_security_group_rule" "fabio-http-api" {
  security_group_id = "${aws_security_group.fabio.id}"
  type              = "ingress"
  from_port         = 9999
  to_port           = 9999
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "fabio-egress" {
  security_group_id = "${aws_security_group.fabio.id}"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

// Launch the ELB that is serving fabio. This has proper health checks
// to only serve healthy fabio instances.
resource "aws_elb" "fabio" {
  name                        = "${format("%s", var.name)}"
  connection_draining         = true
  connection_draining_timeout = 400
  internal                    = true
  subnets                     = ["${split(",", var.subnets)}"]
  security_groups             = ["${aws_security_group.elb.id}"]

  listener {
    instance_port     = 9999
    instance_protocol = "tcp"
    lb_port           = 80
    lb_protocol       = "tcp"
  }

  listener {
    instance_port      = 9999
    instance_protocol  = "tcp"
    lb_port            = 443
    lb_protocol        = "ssl"
    ssl_certificate_id = "${var.ssl_certificate_id}"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    target              = "${var.elb-health-check}"
    interval            = 15
  }
}

resource "aws_security_group" "elb" {
  name        = "fabio-elb"
  description = "fabio ELB"
  vpc_id      = "${var.vpc-id}"
}

resource "aws_security_group_rule" "fabio-elb-http" {
  security_group_id = "${aws_security_group.elb.id}"
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "fabio-elb-https" {
  security_group_id = "${aws_security_group.elb.id}"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "fabio-elb-egress" {
  security_group_id = "${aws_security_group.elb.id}"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

// This rule allows elb to check health endpoint
resource "aws_security_group_rule" "fabio-http-check" {
  security_group_id        = "${aws_security_group.fabio.id}"
  type                     = "ingress"
  from_port                = 9998
  to_port                  = 9998
  protocol                 = "tcp"
  source_security_group_id = "${aws_security_group.elb.id}"
}
