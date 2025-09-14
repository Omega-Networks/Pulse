# Pulse: Unified Infrastructure Platform Architecture

```mermaid
graph LR
    subgraph Sources["Infrastructure Sources"]
        NetBox("<b>NetBox</b><br/>Asset Management")
        Zabbix("<b>Zabbix</b><br/>Monitoring & Alerts")
        Cameras("<b>Cameras</b><br/>Live Feeds")
        IoT("<b>IoT Sensors</b><br/>Environmental Data")
    end

    subgraph PulseCore["Pulse Platform"]
        API("<b>API Layer</b><br/>Data ingestion")
        Cache("<b>Local Cache</b><br/>SwiftData store")
        Memory("<b>Memory</b><br/>Unified Memory")
        Engine("<b>Processing</b><br/>Analytics & AI")
        Viz("<b>Visualization</b><br/>MapKit & SwiftUI")
    end

    subgraph UIs["User Interfaces"]
        macOS("<b>macOS</b><br/>Desktop & Laptop")
        iOS("<b>iOS & iPadOS</b><br/>Mobile & Field Ops")
        tvOS("<b>tvOS</b><br/><i>xOC roadmap</i>")
        visionOS("<b>visionOS</b><br/><i>roadmap</i>")
    end


    NetBox & Zabbix & Cameras & IoT --- PulseCore
    API & Cache --- Memory --- Engine & Viz
    PulseCore --- macOS & iOS & tvOS & visionOS

    classDef subGraphBox fill:#1A3140,opacity:1,stroke-width:0px,color:#FFFFFF,font-size:20px
    classDef nodeBox fill:#348ABF,stroke:#73B1BF,stroke-width:1px,color:#FFFFFF

    class Sources,PulseCore,UIs subGraphBox

    class NetBox,Zabbix,Cameras,IoT nodeBox
    class API,Cache,Memory,Engine,AI,Viz nodeBox
    class macOS,iOS,tvOS,visionOS nodeBox

```

## Understanding the Architecture

### How to Read This Diagram

This diagram shows the three key layers of the Pulse platform and how data flows between them:

**Left to Right Data Flow:**
1. **Infrastructure Sources** (left) → **Pulse Platform** (center) → **User Interfaces** (right)
2. Data is collected from your existing systems, processed and unified, then presented through native Apple interfaces

### Component Details

<details>
<summary><strong>Infrastructure Sources (Input Layer)</strong></summary>

These are your existing systems that Pulse connects to:
- **NetBox**: Provides device inventory, network topology, and asset management data
- **Zabbix**: Supplies real-time monitoring data, alerts, and performance metrics
- **Cameras**: Streams live video feeds for security and operational monitoring
- **IoT Sensors**: Delivers environmental data like temperature, humidity, and power usage

</details>

<details>
<summary><strong>Pulse Platform (Processing Layer)</strong></summary>

The core engine that transforms raw data into actionable insights:
- **API Layer**: Handles secure communication with all data sources using their native APIs
- **Local Cache**: SwiftData-powered local storage for fast access and offline operation
- **Unified Memory**: In-memory data structures that create a single coherent view of your infrastructure
- **Processing Engine**: Local analytics and AI that detect patterns, anomalies, and generate insights
- **Visualization Layer**: Renders data into maps, charts, and interactive displays using MapKit and SwiftUI

</details>

<details>
<summary><strong>User Interfaces (Output Layer)</strong></summary>

Native Apple applications optimized for different use cases:
- **macOS**: Full desktop experience for detailed analysis and administration
- **iOS/iPadOS**: Mobile interface for field work and quick status checks
- **tvOS**: Large-screen dashboards for operations centers (planned feature)
- **visionOS**: 3D infrastructure visualization (future roadmap)

</details>

### Architecture Characteristics

**Local-First Design**: All processing happens on your devices - no data leaves your network unless you choose to sync between your own devices via CloudKit.

**Unified Memory Model**: Instead of querying multiple systems repeatedly, Pulse maintains a comprehensive in-memory model of your entire infrastructure that updates in real-time.

**Native Apple Integration**: Built specifically for Apple's ecosystem using SwiftUI, SwiftData, and platform-specific APIs for optimal performance and user experience.

## Architecture Principles & Impact Philosophy

| Technical Capability | Core Value | Community Benefit |
|---------------------|------------|-------------------|
| **🔒 No Cloud Dependencies** | **Self-Determination** | Complete data sovereignty and local control |
| **🌐 Unified Data Platform** | **Active Stewardship** | Comprehensive monitoring of community infrastructure |
| **🧠 Local Intelligence** | **Self-Sufficiency** | Independent analytics without external dependencies |
| **📱 Native Ecosystem** | **Unified Experience** | Seamless operations across all devices and contexts |
| **🔄 Extensible Design** | **Future-Thinking** | Adaptable platform serving current and future generations |
