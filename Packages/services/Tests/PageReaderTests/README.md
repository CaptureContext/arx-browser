# PageReaderTests

Reading mode's reader (DEV-1028): the vendored Readability loads, every script fits the engine's source limit, the extraction reads a copy of the page and keeps only text markup, an article is put together from its slices, and a page without an article, one that changed while it was read, or one that isn't on the web has none. A busy tab is asked again; an unavailable one isn't readable.
