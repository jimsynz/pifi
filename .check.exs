[
  tools: [
    {:dialyzer, false},
    {:mix_audit, false},
    {:hex_audit, "mix hex.audit"},
    # Config.HTTPS is ignored on purpose. This firmware is a stereo component on
    # a home network, and it answers on its IP address and on more than one mDNS
    # name. A certificate for those names cannot be issued, so HTTPS would only
    # give a browser warning on each visit.
    {:sobelow, "mix sobelow --exit --skip -i Config.HTTPS"}
  ]
]
