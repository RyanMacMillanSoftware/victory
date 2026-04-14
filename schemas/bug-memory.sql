-- schemas/bug-memory.sql
-- Bug memory schema for Victory rig.
--
-- Stores known bug patterns to inject as warnings at polecat sling time.
-- At sling time, bug_memory is queried by file_pattern to surface up to
-- 5 active warnings in the polecat brief.
--
-- status values: active | resolved | deprecated

CREATE TABLE IF NOT EXISTS `bug_memory` (
  `id`               varchar(255) NOT NULL,
  `code_area`        varchar(255) NOT NULL DEFAULT '',
  `file_pattern`     varchar(500) NOT NULL DEFAULT '',
  `bug_title`        varchar(500) NOT NULL DEFAULT '',
  `warning_text`     text         NOT NULL,
  `root_cause`       text         NOT NULL DEFAULT '',
  `fix_summary`      text         NOT NULL DEFAULT '',
  `fix_bead`         varchar(255) NOT NULL DEFAULT '',
  `regression_test`  text         NOT NULL DEFAULT '',
  `occurrence_count` int          NOT NULL DEFAULT '1',
  `status`           varchar(32)  NOT NULL DEFAULT 'active',
  `created_at`       datetime     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`       datetime     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_bug_memory_file_pattern` (`file_pattern`),
  KEY `idx_bug_memory_code_area` (`code_area`),
  KEY `idx_bug_memory_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
