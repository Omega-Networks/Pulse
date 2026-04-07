//
//  Logger.swift
//  Pulse
//
//  Created by Alessio Prescenzo on 18/11/25.
//
import OSLog

// MARK: - PowerSense

extension Logger {
    static let spatialClustering = Logger(subsystem: "pulse.spatial", category: "clustering")
    static let spatialIndexing = Logger(subsystem: "pulse.spatial", category: "indexing")
    static let spatialPerformance = Logger(subsystem: "pulse.spatial", category: "performance")
    static let spatialGPU = Logger(subsystem: "pulse.spatial", category: "gpu")
    static let spatialValidation = Logger(subsystem: "pulse.spatial", category: "validation")
}
