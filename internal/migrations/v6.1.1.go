package migrations

import (
	"log"

	"github.com/jmoiron/sqlx"
	"github.com/knadh/koanf/v2"
	"github.com/knadh/stuffbin"
)

// V6_1_1 adds the 'system' template type to support DB-editable system e-mail templates.
// This is a ListMonkPlus extension migration kept as a patch version so future upstream
// minor versions (eg. v6.2.0+) continue to apply in normal semver order.
func V6_1_1(db *sqlx.DB, fs stuffbin.FileSystem, ko *koanf.Koanf, lo *log.Logger) error {
	// Add 'system' to the template_type enum if not already present.
	if _, err := db.Exec(`
		DO $$
		BEGIN
			IF NOT EXISTS (
				SELECT 1 FROM pg_enum
				WHERE enumtypid = 'template_type'::regtype
				AND enumlabel = 'system'
			) THEN
				ALTER TYPE template_type ADD VALUE 'system';
			END IF;
		END
		$$;
	`); err != nil {
		return err
	}

	return nil
}
