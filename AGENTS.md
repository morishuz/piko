# Repository workflow

Read CONTRIBUTING.md for build, test, and packaging requirements.
Keep changes focused and exclude generated builds and diagnostic reports.

Preserve Piko's privacy defaults: no internet connections and no diagnostic
recording before explicit consent. Keep simulated devices in Tests. Do not
access physical devices without an explicit request.

Keep USB work off the main actor, UI policy out of transport code, and retain
confirmation and recovery safeguards around device writes and deletion.
