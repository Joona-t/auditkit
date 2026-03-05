function calculateScore(items) {
  return items.reduce((sum, item) => sum + item.value, 0);
}

module.exports = { calculateScore };
