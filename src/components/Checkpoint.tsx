import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';

export type CheckpointChoice = 'continue' | 'done' | 'redirect';

interface CheckpointProps {
  reason: string;
  onChoice: (choice: CheckpointChoice) => void;
}

/**
 * Agent loop checkpoint — shown when the model stops calling tools.
 * Lets the user decide: push the model to continue, accept the response, or redirect.
 */
export default function Checkpoint({ reason, onChoice }: CheckpointProps) {
  const [selected, setSelected] = useState(0); // 0=continue, 1=done, 2=redirect
  const options: { label: string; key: string; choice: CheckpointChoice; color: string }[] = [
    { label: 'Continue', key: 'c', choice: 'continue', color: 'green' },
    { label: 'Done', key: 'd', choice: 'done', color: 'blue' },
    { label: 'Redirect', key: 'r', choice: 'redirect', color: 'yellow' },
  ];

  useInput((input, key) => {
    if (key.leftArrow) setSelected(s => (s > 0 ? s - 1 : options.length - 1));
    if (key.rightArrow) setSelected(s => (s < options.length - 1 ? s + 1 : 0));
    if (key.return) onChoice(options[selected]!.choice);
    if (key.escape) onChoice('done');
    if (input === 'c' || input === 'C') onChoice('continue');
    if (input === 'd' || input === 'D') onChoice('done');
    if (input === 'r' || input === 'R') onChoice('redirect');
  });

  return (
    <Box flexDirection="column" marginLeft={2} marginTop={1}>
      <Box>
        <Text dimColor>╭── </Text>
        <Text bold color="cyan">checkpoint</Text>
      </Box>
      <Box>
        <Text dimColor>│ </Text>
        <Text dimColor>{reason}</Text>
      </Box>
      <Box>
        <Text dimColor>├────</Text>
      </Box>
      <Box>
        <Text dimColor>│ </Text>
        {options.map((opt, i) => (
          <React.Fragment key={opt.key}>
            {i > 0 && <Text>  </Text>}
            {i === selected ? (
              <Text color={opt.color} bold inverse> {opt.label} ({opt.key}) </Text>
            ) : (
              <Text dimColor> {opt.label} ({opt.key}) </Text>
            )}
          </React.Fragment>
        ))}
      </Box>
      <Box>
        <Text dimColor>╰── ←→ select  enter confirm  c/d/r shortcut</Text>
      </Box>
    </Box>
  );
}
