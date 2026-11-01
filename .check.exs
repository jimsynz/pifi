[
  tools: [
    {:dialyzer, false},
    {:mix_audit, false},
    {:hex_audit, "mix hex.audit"},
    {:sobelow, "mix sobelow --exit --skip -i Config.HTTPS"}
  ]
]
