import React, { useState, useEffect } from 'react';
import { Text } from 'ink';

const BRAILLE_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

interface SpinnerProps {
  label?: string;
  color?: string;
}

export default function Spinner({ label = 'thinking', color = 'cyan' }: SpinnerProps) {
  const [frame, setFrame] = useState(0);

  useEffect(() => {
    const interval = setInterval(() => {
      setFrame(f => (f + 1) % BRAILLE_FRAMES.length);
    }, 80);
    return () => clearInterval(interval);
  }, []);

  return (
    <Text>
      <Text dimColor>{BRAILLE_FRAMES[frame]} </Text>
      <Text color={color}>{label}</Text>
    </Text>
  );
}
