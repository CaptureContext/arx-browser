# TaskManagerFeatureTests

Every suite that uses dependencies, a store or `@Shared` takes `@Suite(.dependencies)` (DEV-970). Without it, every test in the process shares one set of dependency test values, including swift-sharing's storage and `@Shared` references. A test then reads what another left behind, so it passes alone but fails on a repeat or next to another.

Tests for TaskManagerFeature (DEV-898): sampling only while the window is open, CPU from the change in CPU time between samples, sorting with Arx itself first, and End Process only for renderers.
