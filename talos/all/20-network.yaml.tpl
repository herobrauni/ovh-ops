---
machine:
  network:
    interfaces:
      - deviceSelector:
          hardwareAddr: "{{ .Node.Data.macPrimary }}"
        dhcp: true
      - deviceSelector:
          hardwareAddr: "{{ .Node.Data.macSecondary }}"
        dhcp: false
        # addresses:
        #   - "{{ .Node.Data.secondaryAddr }}"
        # routes:
        #   - gateway: 10.10.8.1
        #     network: 0.0.0.0/0
