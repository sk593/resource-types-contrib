extension radius
extension containers
extension persistentVolumes

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'containers-testapp'
  properties: {
    environment: environment
  }
}

// Create a container that mounts the persistent volume
resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'myapp'
  properties: {
    environment: environment
    application: app.id
    containers: {
      web: {
        image: 'nginx:alpine'
        ports: {
          http: {
            containerPort: 80
          }
        }
      }
    }
  }
}
