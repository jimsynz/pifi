# **The log of a passing test is noise, and the log of a failing one is the answer.**
# `capture_log: true` holds each test's log and prints it only for a test that fails, so
# a run that works says nothing and a run that does not says exactly what went wrong
# where it went wrong.
#
# This firmware writes a great deal of that noise on purpose. A test of a stream that
# cannot be read raises `nxdomain`, a test of the FLAC reader says `flac is not on the
# PATH`, and a test of a pipeline that stops prints a Membrane crash with its whole
# stack. Every one is a test doing its job, and together they buried the one line that
# mattered when CI failed: finding it meant reading three thousand lines of log.
#
# A test that wants to read its own log takes `@tag capture_log: false`, and
# `ExUnit.CaptureLog` still works either way.
ExUnit.start(capture_log: true)
