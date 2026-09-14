# stream-doctor

Automated end-to-end testing for video infrastructure: publish a stream into
your pipeline, watch what comes out the other end and assert on the metrics.
An early proof of concept, currently a single RTMP to HLS scenario with a
single metric, the audio/video drift.

This is the TypeScript client for the StreamDoctor daemon. It brings the
daemon binary along, as an optional dependency on `@stream-doctor/<platform>`.
Setup, usage and the roadmap are described in the
[StreamDoctor repository](https://github.com/membraneframework-labs/stream_doctor).
