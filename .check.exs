[
  tools: [
    {:dialyzer, false},
    {:mix_audit, false},
    {:hex_audit, "mix hex.audit"},
    # This project ignores Config.HTTPS on purpose. The firmware is a stereo
    # component on a home network. It answers on its IP address, and on more than
    # one mDNS name. No authority issues a certificate for those names. HTTPS
    # therefore gives only a browser warning at each visit.
    {:sobelow, "mix sobelow --exit --skip -i Config.HTTPS"}
  ]
]
