// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MysqlDesk",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pure-Swift MySQL/MariaDB driver (no libmysqlclient needed), plus NIO for TLS options.
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.14.0"),
    ],
    targets: [
        .executableTarget(
            name: "MysqlDesk",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/MysqlDesk"
        )
    ]
)
