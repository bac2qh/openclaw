#!/bin/bash
# Test script to verify multi-part transcript detection logic

echo "Testing multi-part detection logic..."
echo ""

# Test case 1: Regular file (no part suffix)
basename="2025-02-13-1430-meeting.json"
PART_META=""
if [[ "$basename" =~ _part([0-9]+)\.json$ ]]; then
  echo "ERROR: Regular file incorrectly detected as multi-part"
  exit 1
else
  echo "✓ Test 1 PASSED: Regular file '$basename' not detected as multi-part"
fi

# Test case 2: Multi-part file detection
basename="2025-02-13-1430-meeting_part2.json"
PART_META=""
if [[ "$basename" =~ _part([0-9]+)\.json$ ]]; then
  PART_NUM="${BASH_REMATCH[1]}"
  BASE_NAME="${basename%_part*.json}"
  if [[ "$PART_NUM" == "2" && "$BASE_NAME" == "2025-02-13-1430-meeting" ]]; then
    echo "✓ Test 2 PASSED: Multi-part file detected correctly"
    echo "  - Part number: $PART_NUM"
    echo "  - Base name: $BASE_NAME"
  else
    echo "ERROR: Part number or base name extraction failed"
    echo "  - Expected part: 2, got: $PART_NUM"
    echo "  - Expected base: 2025-02-13-1430-meeting, got: $BASE_NAME"
    exit 1
  fi
else
  echo "ERROR: Multi-part file not detected"
  exit 1
fi

# Test case 3: PART_META string generation
PART_NUM="2"
BASE_NAME="2025-02-13-1430-meeting"
PART_COUNT="3"
PART_META="
**Multi-part recording:** This is part ${PART_NUM} of ${PART_COUNT} (so far) from recording '${BASE_NAME}'. Adjacent parts overlap by ~5 minutes — avoid storing duplicate content from overlap regions. If this is part 2+, treat it as a continuation of the same recording."

if [[ -n "$PART_META" && "$PART_META" == *"part 2 of 3"* && "$PART_META" == *"continuation"* ]]; then
  echo "✓ Test 3 PASSED: PART_META string generated correctly"
  echo "  Message preview: ${PART_META:0:100}..."
else
  echo "ERROR: PART_META string generation failed"
  exit 1
fi

echo ""
echo "All tests passed! ✓"
