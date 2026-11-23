#ifndef ARX_EXTERNAL_CONSENT_FIXTURE_H_
#define ARX_EXTERNAL_CONSENT_FIXTURE_H_
#include "base/functional/callback.h"
#include "base/files/file_path.h"
#include <string>
class GURL;
namespace content { class WebContents; }
namespace arx::consent_testing {
// Requires explicit mock Keychain and one-use, private owned runner metadata.
// When armed ALL final OS launches are intercepted, including unexpected ones.
bool Initialize(const base::FilePath& profile_root, bool mock_keychain);
void Reset();
void DialogShown(content::WebContents* child, content::WebContents* source,
                 const GURL&, const std::u16string& program,
                 base::RepeatingCallback<bool()> current,
                 base::RepeatingCallback<bool()> visible,
                 base::OnceClosure cancel, base::OnceClosure accept,
                 content::WebContents* original_source = nullptr);
void ChildDestroyed(const GURL&);
void PublishedNavigationStarted(content::WebContents*, const GURL&, bool primary);
void PublishedAttributionDrained(const GURL&);
void PublishedAttributionDiagnostic(content::WebContents* original_source, int stage, int detail);
}  // namespace arx::consent_testing
#endif
