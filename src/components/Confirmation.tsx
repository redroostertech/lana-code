import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';

interface ConfirmationProps {
  label: string;
  content?: string;
  description?: string;
  warning?: string;
  onConfirm: () => void;
  onReject: () => void;
}

/**
 * Accept/reject dialog with arrow key navigation.
 * Port of ui_tool_confirm from ui.sh.
 */
export default function Confirmation({
  label,
  content,
  description,
  warning,
  onConfirm,
  onReject,
}: ConfirmationProps) {
  const [selected, setSelected] = useState(0); // 0 = Yes, 1 = No

  useInput((input, key) => {
    if (key.leftArrow || key.rightArrow) {
      setSelected(s => (s === 0 ? 1 : 0));
    }
    if (key.return) {
      if (selected === 0) onConfirm();
      else onReject();
    }
    if (key.escape) {
      onReject();
    }
    if (input === 'y' || input === 'Y') {
      onConfirm();
    }
    if (input === 'n' || input === 'N') {
      onReject();
    }
  });

  return (
    <Box flexDirection="column" marginLeft={2} marginTop={1}>
      {/* Header */}
      <Box>
        <Text dimColor>╭── </Text>
        <Text bold>{label}</Text>
      </Box>

      {/* Content preview */}
      {content && (
        <Box flexDirection="column">
          {content.split('\n').slice(0, 10).map((line, i) => (
            <Box key={i}>
              <Text dimColor>│ </Text>
              <Text>{line}</Text>
            </Box>
          ))}
          {content.split('\n').length > 10 && (
            <Box>
              <Text dimColor>│ ... ({content.split('\n').length} lines)</Text>
            </Box>
          )}
        </Box>
      )}

      {/* Description */}
      {description && (
        <Box>
          <Text dimColor>│ </Text>
          <Text dimColor>{description}</Text>
        </Box>
      )}

      {/* Warning */}
      {warning && (
        <Box>
          <Text dimColor>│ </Text>
          <Text color="yellow">⚠ {warning}</Text>
        </Box>
      )}

      {/* Separator */}
      <Box>
        <Text dimColor>├────</Text>
      </Box>

      {/* Options */}
      <Box>
        <Text dimColor>│ </Text>
        <Text>Do you want to proceed? </Text>
        {selected === 0 ? (
          <>
            <Text color="green" bold inverse> Yes </Text>
            <Text>  </Text>
            <Text dimColor> No </Text>
          </>
        ) : (
          <>
            <Text dimColor> Yes </Text>
            <Text>  </Text>
            <Text color="red" bold inverse> No </Text>
          </>
        )}
      </Box>

      {/* Footer */}
      <Box>
        <Text dimColor>╰── ←→ select  enter confirm  esc cancel</Text>
      </Box>
    </Box>
  );
}
