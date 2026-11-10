-- 匿名使用人數: one row per random id per day (see src/index.js /hello).
CREATE TABLE IF NOT EXISTS seen (
  day TEXT NOT NULL,
  id TEXT NOT NULL,
  ver TEXT NOT NULL,
  platform TEXT NOT NULL,
  PRIMARY KEY (day, id)
);
CREATE INDEX IF NOT EXISTS seen_day ON seen (day);
