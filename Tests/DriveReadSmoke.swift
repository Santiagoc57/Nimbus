import Foundation
@main struct ReadSmoke {
 static func main() async throws {
  let p=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Nimbo/rclone.conf")
  let api=DriveAPI(configuration:p)
  let root=try await api.item("root")
  guard root.isFolder, !root.id.isEmpty else { throw DriveFailure.invalidResponse }
  let page=try await api.children(root.id)
  guard !page.files.isEmpty, page.files.allSatisfy({!$0.id.isEmpty}) else { throw DriveFailure.invalidResponse }
  let anchor=try await api.currentAnchor()
  let changes=try await api.changes(since:anchor)
  let report:[String:Any]=["status":"PASS","real_drive":true,"read_only":true,"root_id_resolved":true,"first_page_count":page.files.count,"change_feed_read":true,"next_anchor_present":changes.newStartPageToken != nil,"file_contents_downloaded":false]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"outputs/Nimbo/NATIVE_DRIVE_API_READ_TEST.json"))
  print("PASS: native Google API root identity, listing and change feed; metadata only.")
 }
}
