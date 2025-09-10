//
//  NetboxAddSiteModal.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Pulse
//  The Platform for Unified Leadership in Smart Environments.
//
//  This program is distributed to enable communities to build and maintain their own
//  digital sovereignty through local control of critical infrastructure data.
//
//  By open sourcing Pulse, we create a circular economy where contributors can both build
//  upon and benefit from the platform, ensuring that value flows back to communities rather
//  than being extracted by external entities. This aligns with our commitment to intergenerational
//  prosperity through collaborative stewardship of public infrastructure.
//
//  This program is free software: communities can deploy it for sovereignty, academia can
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import SwiftUI
import SwiftData

#if os(macOS)
struct AddSiteWindow: View {
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.modelContext) private var modelContext
    
    @Environment(SharedLocations.self) private var sharedLocations  // Inject the shared instance
    
    @State private var selectedName: String = ""
    @State private var selectedStatus: String = ""
    @State private var selectedRegion: String = ""
    @State private var selectedGroup: String = ""
    @State private var selectedTimeZone: String = "Pacific/Auckland" //TODO: Include timeZone as a property in SiteProperties
    @State private var selectedDescription: String = ""
    @State private var selectedTags: String = ""
    @State private var selectedTenantGroup: String = ""
    @State private var selectedTenant: String = ""
    @State private var selectedPhysicalAddress: String = ""
    //MARK: Variable for storing state of checkbox goes here
    @State private var sameAsShippingAddress = false
    @State private var selectedShippingAddress: String = ""
    @State private var selectedLongitude: Double = 0
    @State private var selectedLatitude: Double = 0
    @State private var selectedIdentifier: String = ""
    @State private var selectedComments: String = ""
    @State private var selectedDisplay: String = ""
    @State private var selectedURL: String = ""
    
    //Boolean for validating that all mandatory fields are filled
    @State private var validationFailed: Bool = false
    //To prevent devices with multiple names
    @State private var isDuplicateName: Bool = false
    
    //SwiftData Queries
    @Query var tenantGroups: [TenantGroup]
    @Query var siteGroups: [SiteGroup]
    @Query var sites: [Site]
    @Query var tenants: [Tenant]
    @Query var regions: [Region]
    
    var allTenantGroups: [String] {
        return Array(Set(tenantGroups.compactMap { $0.name })).sorted()
    }
    
    var allSiteGroups: [String] {
        return Array(Set(siteGroups.compactMap { $0.name })).sorted()
    }
    
    var allTenants: [String] {
        //MARK: Since tenant groups cannot be populated properly, pulling all Tenants for now
        return Array(Set(tenants.compactMap { $0.name })).sorted()
    }
    
    var allRegions: [String] {
        return Array(Set(regions.compactMap { $0.name })).sorted()
    }
    
    let statusArray = [
        "Active",
        "Planned"
    ]
    
    var body: some View {
        ScrollView {
            VStack (alignment: .leading) {
                //MARK: Error message if mandatory fields are not filled, or duplicate names found
                
                //TODO: Replace Groups with Sections
                Form {
                    Section(header:
                                Text("Site")
                        .font(.title)
                        .fontWeight(.bold)
                    ) {
                        
                        /// Name
                        TextField("Name*:", text: $selectedName)
                            .fontWeight(.bold)
                            .lineLimit(10)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(width: 553)
                            .border((validationFailed && selectedName.isEmpty) || isDuplicateName ? Color.red : Color.clear, width: 2)
                            .cornerRadius(5)
                        
                        /// Status
                        Picker(selection: $selectedStatus, label: Text("Status*:")) {
                            ForEach(statusArray, id: \.self) { status in
                                Text(status).tag(status)
                            }
                        }
                        .pickerStyle(.menu)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .border(validationFailed && selectedStatus.isEmpty ? Color.red : Color.clear, width: 2)
                        .cornerRadius(5)
                        
                        //TODO: Add nesting to drop down menu for regions
                        /// Region
                        Picker(selection: $selectedRegion, label: Text("Region")) {
                            ForEach(allRegions, id: \.self) { region_netbox in
                                Text(region_netbox).tag(region_netbox)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.vertical, 1)
                        
                        /// Group
                        Picker(selection: $selectedGroup, label: Text("Group")) {
                            ForEach(allSiteGroups, id: \.self) { group in
                                Text(group).tag(fetchSiteGroupIdByName(group))
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.vertical, 1)
                        .onChange(of: selectedGroup) {
                            print("Site Group name from Picker: \(selectedGroup)")
                        }
                        
                        /// Time Zone
                        Text("Time Zone: \(selectedTimeZone)")
                            .fontWeight(.bold)
                            .padding(.top, 2)
                        
                        /// Description
                        TextField("Description:", text: $selectedDescription)
                            .lineLimit(10)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 553)
                            .padding(.vertical, 1)
                        
                        /// Tags
                        TextField("Tags:", text: $selectedTags)
                            .lineLimit(10)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 553)
                            .padding(.vertical, 1)
                    }
                    
                    Section(header:
                                Text("Tenancy")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.top, 25)
                    ) {
                        /// Tenant Group
                        Picker(selection: $selectedTenantGroup, label: Text("Tenant Group:")) {
                            ForEach(allTenantGroups, id: \.self) { tenantGroup in
                                Text(tenantGroup).tag(tenantGroup)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.vertical, 1)
                        
                        /// Tenant
                        Picker(selection: $selectedTenant, label: Text("Tenant:")) {
                            ForEach(allTenants, id: \.self) { tenant in
                                Text(tenant).tag(tenant)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.vertical, 1)
                    }
                    
                    Section(header:
                                Text("Contact Info")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.top, 25)
                    ) {
                        /// Physical Address
                        TextField("Physical Address:", text: $selectedPhysicalAddress)
                            .lineLimit(10)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 553)
                            .padding(.vertical, 1)
                        
                        /// Shipping Address
                        TextField("Shipping Address:", text: $selectedShippingAddress)
                            .lineLimit(10)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 553)
                            .padding(.vertical, 1)
                        
                        //TODO : Ensure nothing occurs when checkbox is unticked
                        Toggle(isOn: $sameAsShippingAddress) {
                            Text("Same as physical address")
                        }
                        .toggleStyle(.checkbox)
                        .onChange(of: sameAsShippingAddress) {
                            if sameAsShippingAddress == true {
                                // When the Toggle is enabled, set the shipping address to be the sfame as the physical address
                                selectedShippingAddress = sharedLocations.tapAddress ?? ""
                            } else {
                                // When the Toggle is disabled, clear the shipping address
                                selectedShippingAddress = ""
                            }
                        }
                        
                        /// Latitude
                        Text("Latitude: \(String(format: "%.8f", sharedLocations.tapLocation?.latitude ?? 0.0))")
                            .fontWeight(.bold)
                            .padding(.top, 10)
                            .textSelection(.enabled)
                        
                        Text("Longitude: \(String(format: "%.9f", sharedLocations.tapLocation?.longitude ?? 0.0))")
                            .fontWeight(.bold)
                            .padding(.top, 2)
                            .textSelection(.enabled)
                        
                    }
                    
                    Section(header:
                                Text("Custom Fields")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.top, 25) 
                    ) {
                        /// Identifier
                        TextField("Identifier:", text: $selectedIdentifier)
                            .lineLimit(10)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 553)
                            .padding(.vertical, 1)
                        
                        //TODO: Add TextEditor for Comments
                    }
                }
                .padding(.horizontal, 120)
                
                HStack {
                    Spacer()
                    
                    /// Update
                    Button {
                        Task.detached(priority: .background) {
                            await validateSiteCreation()
                        }
                    } label: {
                        Text("Create")
                            .frame(width: 80)
                            .foregroundColor(.white)
                    }
                    .cornerRadius(5)
                    
                    /// Cancel
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Text("Cancel")
                            .frame(width: 80)
                            .foregroundColor(.white)
                            .cornerRadius(5)
                    }
                    .padding(.trailing, 200)
                }
                .padding(.top, 80)
                
            }
            .frame(minWidth: 800, maxWidth: .infinity, minHeight: 800, idealHeight: 1000, maxHeight: .infinity)
            .padding(1)
        }
        .onChange(of: selectedTenantGroup) {
            // Check if the current tenant is part of the new group
            if !allTenants.contains(selectedTenant) {
                // Reset the selected tenant to the first tenant in the new group or to an empty string
                selectedTenant = ""
            }
        }
        .onAppear {
            if let tapAddress = sharedLocations.tapAddress {
                self.selectedPhysicalAddress = tapAddress
            }
        }
    }
    
    //MARK: Functions for the AddSiteWindow view
    private func validateSiteCreation() async {
        if selectedName.isEmpty || selectedStatus.isEmpty {
            validationFailed = true
        } else if checkForDuplicateName() {
            isDuplicateName = true
        } else {
            validationFailed = false
            let properties = await createSiteProperties()
            
            //Temporary print block for testing
            print("Verifying Site Properties:")
            print("  Name: \(properties.name)")
            print("  Region ID: \(properties.regionId)")
            print("  Group ID: \(properties.groupId)")
            print("  Tenant ID: \(properties.tenantId)")
            print("  Physical Address: \(properties.physicalAddress)")
            print("  Shipping Address: \(properties.shippingAddress)")
            print("  Latitude: \(properties.latitude)")
            print("  Longitude: \(properties.longitude)")
            
            // Uncomment the following line when ready to actually post the site
             await ProviderModelActor(modelContainer: modelContext.container).postSite(with: properties)
            
            await MainActor.run {
                presentationMode.wrappedValue.dismiss()
            }
        }
    }
    
    private func fetchSiteGroupIdByName(_ name: String) -> Int64 {
        let predicate = #Predicate<SiteGroup> { siteGroup in
            siteGroup.name == name
        }
        
        let fetchDescriptor = FetchDescriptor(predicate: predicate)
        
        do {
            let fetchedSiteGroups = try modelContext.fetch(fetchDescriptor)
            guard let matchingSiteGroup = fetchedSiteGroups.first else {
                print("No site groups matched do.")
                return 0
            }
            return matchingSiteGroup.id
        } catch {
            print("No site groups matched catch.")
            return 0
        }
    }
    
    private func fetchTenantIdByName(_ name: String) async -> Int64 {
        let predicate = #Predicate<Tenant> { tenant in
            tenant.name == name
        }
        
        let fetchDescriptor = FetchDescriptor(predicate: predicate)
        
        do {
            let tenants = try modelContext.fetch(fetchDescriptor)
            guard let matchingTenant = tenants.first else {
                print("No tenants matched do.")
                return 0
            }
            return matchingTenant.id
        } catch {
            print("No tenants matched catch.")
            return 0
        }
    }
    
    private func fetchRegionIdByName(_ name: String) async -> Int64 {
        let predicate = #Predicate<Region> { region_netbox in
            region_netbox.name == name
        }
        
        let fetchDescriptor = FetchDescriptor(predicate: predicate)
        
        do {
            let regions = try modelContext.fetch(fetchDescriptor)
            guard let matchingRegion = regions.first else {
                print("No regions matched do.")
                return 0
            }
            return matchingRegion.id
        } catch {
            print("No regions matched catch.")
            return 0
        }
    }
    
    private func generateSlug(from name: String) -> String {
        return name.lowercased().replacingOccurrences(of: " ", with: "-")
    }
    
    private func checkForDuplicateName() -> Bool {
        return sites.contains { $0.name == selectedName }
    }
    
    func createSiteProperties() async -> SiteProperties {
        ///Reducing latitude and longitude values to five digits
        let formattedLatitude = String(format: "%.5f", sharedLocations.tapLocation?.latitude ?? 0.0)
        let formattedLongitude = String(format: "%.5f", sharedLocations.tapLocation?.longitude ?? 0.0)
        
        let siteProperties = SiteProperties(
            name: selectedName,
            slug: generateSlug(from: selectedName),
            status: selectedStatus,
            display: selectedDisplay,
            url: selectedURL,
            latitude: Double(formattedLatitude) ?? 0.0,
            longitude: Double(formattedLongitude) ?? 0.0,
            physicalAddress: sharedLocations.tapAddress ?? "",
            shippingAddress: selectedShippingAddress,
            groupId: fetchSiteGroupIdByName(selectedGroup),
            regionId: await fetchRegionIdByName(selectedRegion),
            tenantId: await fetchTenantIdByName(selectedTenant)
        )
        
        return siteProperties
    }
}

#else
#endif
//
//#Preview {
//    AddSiteWindow()
//}
