extension radius
extension containers

param environment string

resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'testapp'
  location: 'global'
  properties: {
    environment: environment
    extensions: [
      {
        kind: 'kubernetesNamespace'
        namespace: 'testapp'
      }
    ]
  }
}

resource myContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'myContainer'
  properties: {
    environment: environment
    application: app.id
    containers: {
      demo: {
        image: 'mcr.microsoft.com/azuredocs/aci-helloworld'
      }
    }
  }
}
