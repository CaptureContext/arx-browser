# BrowserCaptureTests

Tests BrowserCaptureClient image processing and BrowserCore capture contracts using generated RGBA PNG fixtures. Covers fractional coordinate mapping, crop colors, alpha-to-JPEG white compositing, bounds, malformed metadata, format consistency, Unicode filenames and atomic destination failures. Runs on macOS without a renderer. These fixtures do not establish native Chromium capture support.

Document-image tests preserve negative extent origins and independent viewport/device metadata while cropping in frozen image points; mismatched mode, dimensions and raster scale are rejected.
