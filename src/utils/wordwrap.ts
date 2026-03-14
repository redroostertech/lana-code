/**
 * Word-wrap text to fit within a given column width.
 * Breaks on word boundaries (spaces) and preserves existing newlines.
 * Falls back to character-level break only for words longer than the width.
 */
export function wordWrap(text: string, width: number): string {
  if (width <= 0) return text;

  const inputLines = text.split('\n');
  const outputLines: string[] = [];

  for (const line of inputLines) {
    if (line.length <= width) {
      outputLines.push(line);
      continue;
    }

    // Wrap this line at word boundaries
    const words = line.split(/( +)/); // preserve spaces as separate tokens
    let current = '';

    for (const word of words) {
      if (current.length + word.length <= width) {
        current += word;
      } else if (current === '') {
        // Single word longer than width — force character break
        for (let i = 0; i < word.length; i += width) {
          outputLines.push(word.slice(i, i + width));
        }
      } else {
        // Push current line, start new one with this word
        outputLines.push(current.trimEnd());
        current = word.trimStart();
      }
    }
    if (current) {
      outputLines.push(current);
    }
  }

  return outputLines.join('\n');
}

/**
 * Get available text width, accounting for left indent.
 */
export function getTextWidth(indent: number = 2): number {
  return (process.stdout.columns || 80) - indent;
}
