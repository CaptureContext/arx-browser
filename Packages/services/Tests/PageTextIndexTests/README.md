# PageTextIndexTests

History page text (DEV-1068): a word from a page finds it with its passage, by the start of the word and without accents, in its own profile only, with the query's punctuation and FTS syntax read as words. A page visited again keeps only its new text; each page keeps its first 10,000 characters; the oldest pages go past the limit. Clear History deletes the file, a range or Delete from History removes those pages, and their words aren't left in the file. A measurement prints how much disk 1,000 full pages take.
