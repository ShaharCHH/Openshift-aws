global
    log stdout format raw local0
    maxconn 4096

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 50s
    timeout server 50s
    retries 3

frontend api
    bind *:6443
    default_backend api_backend

backend api_backend
    balance roundrobin
%{ for b in api_backends ~}
    server ${b.name} ${b.ip}:6443 check
%{ endfor ~}

frontend machine_config_server
    bind *:22623
    default_backend mcs_backend

backend mcs_backend
    balance roundrobin
%{ for b in mcs_backends ~}
    server ${b.name} ${b.ip}:22623 check
%{ endfor ~}

frontend ingress_https
    bind *:443
    default_backend ingress_https_backend

backend ingress_https_backend
    balance roundrobin
%{ for b in ingress_backends ~}
    server ${b.name} ${b.ip}:443 check
%{ endfor ~}

frontend ingress_http
    bind *:80
    default_backend ingress_http_backend

backend ingress_http_backend
    balance roundrobin
%{ for b in ingress_backends ~}
    server ${b.name} ${b.ip}:80 check
%{ endfor ~}
