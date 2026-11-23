#ifndef ARX_INSPECTION_BRIDGE_H_
#define ARX_INSPECTION_BRIDGE_H_

#include "chrome/browser/arx/ChromiumBridge.h"
namespace content { class WebContents; }

namespace arx {
using InspectionReply = void (*)(uint64_t request, uint64_t page,
                                 ArxInspectionStatus status, const uint8_t* json, size_t size);
void InspectPage(content::WebContents* contents, uint64_t page, uint64_t request,
                 const char* scope, ArxInspectionLimits limits, InspectionReply reply);
void ValidateInspectionReference(uint64_t page, uint64_t request, const char* scope,
                                 const char* snapshot, const char* reference, InspectionReply reply);
void InspectFrame(content::WebContents* contents, uint64_t page, uint64_t request,
                  const char* scope, const char* frame, ArxInspectionWindow window,
                  InspectionReply reply);
bool InspectionDocumentIsCurrent(uint64_t page, const char* scope, const char* snapshot);
using ReferenceClickReply = void (*)(uint64_t request, uint64_t page,
                                    int32_t disposition, int32_t status);
void ClickInspectionReference(uint64_t page, uint64_t request, const char* scope,
                              const char* snapshot, const char* reference,
                              const char* operation, uint32_t timeout_ms, ReferenceClickReply reply);
void PerformInspectionFormAction(uint64_t page, uint64_t request, const char* scope,
                                 const char* snapshot, const char* reference,
                                 const char* operation, ArxFormActionKind kind,
                                 const uint8_t* bytes, size_t length, uint32_t timeout_ms,
                                 ReferenceClickReply reply);
void ScrollInspectionReference(uint64_t page, uint64_t request, const char* scope,
                               const char* snapshot, const char* reference,
                               const char* operation, ArxScrollAxis axis,
                               double delta_css_pixels, uint32_t timeout_ms, ReferenceClickReply reply);
void CancelReferenceClick(uint64_t request);
void CancelInspection(uint64_t request);
void RevokeInspectionScope(const char* scope);
void ForgetInspectionPage(uint64_t page);
void StopInspections();
}  // namespace arx
#endif
