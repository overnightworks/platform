# platform

The platform of the overnightworks apps: k3s on one machine, with Flux reconciling its whole state from Git. This
repository is that Git source, plus the few small tools that no maintained tool covers.

It is not an application and holds no app code or libraries. Libraries release through their own CI-gated GitHub
releases.

The plan and the target picture are in [overnightworks/platform#1](https://github.com/overnightworks/platform/issues/1).
