
# dns-proxy-deployment.tf
resource "kubernetes_deployment_v1" "dns_proxy_external" {
  metadata {
    name      = "dns-proxy-external"
    namespace = "confluent"
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "dns-proxy-external"
      }
    }

    template {
      metadata {
        labels = {
          app = "dns-proxy-external"
        }
      }

      spec {
        container {
          name  = "coredns"
          image = "coredns/coredns:1.11.1"

          port {
            container_port = 53
            protocol       = "UDP"
          }

          port {
            container_port = 53
            protocol       = "TCP"
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/coredns"
          }

          args = ["-conf", "/etc/coredns/Corefile"]
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.dns_proxy_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_config_map_v1" "dns_proxy_config" {
  metadata {
    name      = "dns-proxy-config"
    namespace = "confluent"
  }

  data = {
    Corefile = <<-EOF
      .:53 {
          
          # Rule 1: Conditional forwarding for cluster-local domains
          cluster.local:53 {
              forward . 172.20.0.10  # Target the actual EKS CoreDNS ClusterIP
              cache 30
          }
          
          # Rule 2: Forward all other queries to the EKS VPC's stable default DNS resolver
          .:53 {
              forward . 10.19.0.2 # Use cidrhost(module.vpc.vpc_cidr_block, 2)
              cache 30
          }
      }
    EOF
  }
}

resource "kubernetes_service_v1" "dns_proxy_external" {
  metadata {
    name      = "dns-proxy-external"
    namespace = "confluent"
  }

  spec {
    selector = {
      app = "dns-proxy-external"
    }

    port {
      name        = "dns-udp"
      port        = 53
      target_port = 53
      protocol    = "UDP"
    }

    port {
      name        = "dns-tcp"
      port        = 53
      target_port = 53
      protocol    = "TCP"
    }
    type = "NodePort"
  }
}


