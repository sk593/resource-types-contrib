#!/bin/bash

# Common configuration and functions for workflow validation

# Define common configuration
setup_config() {
  resource_folders=("Security" "Compute")
  declare -g -A folder_to_namespace=(
    ["Security"]="Radius.Security"
    ["Compute"]="Radius.Compute"
  )
}

# Find YAML files in resource folders
find_yaml_files() {
  local yaml_files=()
  for folder in "${resource_folders[@]}"; do
    if [[ -d "./$folder" ]]; then
      echo "Searching in folder: $folder" >&2
      while IFS= read -r -d '' file; do
        yaml_files+=("$file")
      done < <(find "./$folder" -name "*.yaml" -type f -print0)
    else
      echo "Folder $folder does not exist, skipping..." >&2
    fi
  done
  
  if [[ ${#yaml_files[@]} -eq 0 ]]; then
    echo "No YAML files found in any resource type folders" >&2
    exit 0
  fi
  
  printf '%s\n' "${yaml_files[@]}"
}

# Find recipe files with specific pattern (only in configured resource folders)
find_recipe_files() {
  local pattern="$1"
  local recipe_files=()
  
  for folder in "${resource_folders[@]}"; do
    if [[ -d "./$folder" ]]; then
      echo "Searching for recipes in folder: $folder" >&2
      while IFS= read -r -d '' f; do
        recipe_files+=("$f")
      done < <(find "./$folder" -path "$pattern" -type f -print0)
    else
      echo "Folder $folder does not exist, skipping recipe search..." >&2
    fi
  done
  
  printf '%s\n' "${recipe_files[@]}"
}

# Find and validate recipes (common pattern)
find_and_validate_recipes() {
  local pattern="$1"
  local recipe_type="$2"
  
  readarray -t recipes < <(find_recipe_files "$pattern")
  
  if [[ ${#recipes[@]} -eq 0 ]]; then
    echo "No $recipe_type recipe files found" >&2
    exit 0
  fi
  
  echo "Found ${#recipes[@]} $recipe_type recipes" >&2
  printf '%s\n' "${recipes[@]}"
}

# Extract path components from recipe file
extract_recipe_info() {
  local recipe_file="$1"
  local relpath="${recipe_file#./}"
  IFS='/' read -r root_folder resource_type _recipes_dir platform_service file_name <<< "$relpath"
  
  if [[ -z "$root_folder" || -z "$resource_type" || -z "$platform_service" ]]; then
    echo "❌ Unexpected recipe path structure: $recipe_file" >&2
    exit 1
  fi
  
  echo "$root_folder $resource_type $platform_service $file_name"
}

# Get Radius namespace for folder
get_radius_namespace() {
  local root_folder="$1"
  local radius_namespace="${folder_to_namespace[$root_folder]}"
  
  if [[ -z "$radius_namespace" ]]; then
    echo "❌ Unknown root folder: $root_folder" >&2
    exit 1
  fi
  
  echo "$radius_namespace"
}

# Configure Azure provider in Radius environment
configure_azure_provider() {
  echo "Configuring Azure provider in Radius environment..."
  
  # Check required environment variables
  if [[ -z "$AZURE_CLIENT_ID" || -z "$AZURE_CLIENT_SECRET" || -z "$AZURE_TENANT_ID" || -z "$AZURE_SUBSCRIPTION_ID" ]]; then
    echo "❌ Missing required Azure environment variables:"
    echo "   AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID"
    exit 1
  fi
  
  echo "Registering Azure provider with Radius..."
  if rad env update default --azure-subscription-id "$AZURE_SUBSCRIPTION_ID" --azure-resource-group "radius-test-rg-$(date +%s)"; then
    echo "✅ Azure provider configured successfully"
  else
    echo "❌ Failed to configure Azure provider"
    exit 1
  fi
  
  # Configure Azure credentials for deployment
  echo "Setting up Azure authentication..."
  if az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" --tenant "$AZURE_TENANT_ID"; then
    echo "✅ Azure authentication successful"
  else
    echo "❌ Azure authentication failed"
    exit 1
  fi
  
  # Set default subscription
  az account set --subscription "$AZURE_SUBSCRIPTION_ID"
  echo "✅ Azure provider configuration completed"
}

# Cleanup Azure resources (basic resource group cleanup)
cleanup_azure_resources() {
  local resource_group_pattern="radius-test-rg-*"
  
  echo "Cleaning up Azure test resources..."
  
  # List and delete test resource groups
  resource_groups=$(az group list --query "[?starts_with(name, 'radius-test-rg-')].name" -o tsv 2>/dev/null || echo "")
  
  if [[ -n "$resource_groups" ]]; then
    echo "Found test resource groups to clean up:"
    echo "$resource_groups"
    
    for rg in $resource_groups; do
      echo "Deleting resource group: $rg"
      az group delete --name "$rg" --yes --no-wait || echo "Failed to delete $rg"
    done
    
    echo "✅ Azure cleanup initiated (running in background)"
  else
    echo "No Azure test resource groups found to clean up"
  fi
}

# Deploy and cleanup test application
deploy_and_cleanup_test_app() {
  local test_app_path="$1"
  local deployment_name="$2"
  local description="$3"
  
  if [[ -f "$test_app_path" ]]; then
    echo ""
    echo "🚀 Deploying test application $description..."
    
    echo "Deploying $test_app_path as application: $deployment_name"
    if rad deploy "$test_app_path" --application "$deployment_name"; then
      echo "✅ Successfully deployed test application $description"
      
      # Clean up immediately
      echo "Cleaning up deployment: $deployment_name"
      
      if rad app delete "$deployment_name" --yes; then
        echo "✅ rad app delete succeeded"
          
      else
        echo "⚠️ rad app delete failed with exit code $?"
      fi
      
      echo "✅ Cleanup attempt completed"
    else
      echo "❌ Failed to deploy test application $description"
      exit 1
    fi
  else
    echo "ℹ️ No test application found at $test_app_path, skipping deployment test..."
  fi
}


# Create resource types from YAML files
create_resource_types() {
  echo "Finding YAML files in resource type folders..."
  readarray -t all_yaml_files < <(find_yaml_files)

  echo "Creating resource types..."
  for yaml_file in "${all_yaml_files[@]}"; do
    echo "Processing: $yaml_file"

    # Extract resource type name from the file path
    resource_name=$(basename "$yaml_file" .yaml)

    echo "Creating resource type '$resource_name' from $yaml_file..."
    if rad resource-type create "$resource_name" -f "$yaml_file"; then
      echo "✅ Successfully created resource type: $resource_name"
    else
      echo "❌ Failed to create resource type: $resource_name"
      exit 1
    fi
  done

  echo "✅ All resource types created successfully"
}

# Verify that expected resource types are present
verify_resource_types() {
  echo "Listing all resource types..."
  rad resource-type list
  
  echo "Verifying expected resource types..."
  
  # Build expected resource types list dynamically
  expected_resource_types=()
  readarray -t all_yaml_files < <(find_yaml_files)
  
  for yaml_file in "${all_yaml_files[@]}"; do
    # Extract folder from path to get namespace
    folder=$(echo "$yaml_file" | cut -d'/' -f2)
    radius_namespace="${folder_to_namespace[$folder]}"
    resource_name=$(basename "$yaml_file" .yaml)
    expected_resource_types+=("$radius_namespace/$resource_name")
  done
  
  if [[ ${#expected_resource_types[@]} -eq 0 ]]; then
    echo "No expected resource types found"
    exit 0
  fi
  
  echo "Expected resource types:"
  printf '%s\n' "${expected_resource_types[@]}"
  
  # Get the list of resource types
  resource_type_list=$(rad resource-type list)
  
  verification_failed=false
  
  for expected_type in "${expected_resource_types[@]}"; do
    echo "Checking for resource type: $expected_type"
    
    if echo "$resource_type_list" | grep -q "$expected_type"; then
      echo "✅ Found resource type: $expected_type"
    else
      echo "❌ Missing resource type: $expected_type"
      verification_failed=true
    fi
  done
  
  if [[ "$verification_failed" == "true" ]]; then
    echo "❌ Resource type verification failed"
    echo "Expected resource types not found in the list"
    exit 1
  else
    echo "✅ All expected resource types are present"
  fi
}

# Publish Bicep extensions for all YAML files
publish_bicep_extensions() {
  echo "Publishing Bicep extensions for all YAML files..."
  readarray -t all_yaml_files < <(find_yaml_files)

  for yaml_file in "${all_yaml_files[@]}"; do
    echo "Publishing extension for $yaml_file..."

    resource_name=$(basename "$yaml_file" .yaml)
    extension_name="${resource_name}-extension"

    echo "Publishing extension '$extension_name.tgz' from $yaml_file..."
    if rad bicep publish-extension -f "$yaml_file" --target "$extension_name.tgz"; then
      echo "✅ Successfully published extension: $extension_name.tgz"
    else
      echo "❌ Failed to publish extension: $extension_name.tgz"
      exit 1
    fi
  done

  echo "✅ All Bicep extensions published successfully"
}

# Publish Bicep recipes to registry (for specific platform)
publish_bicep_recipes() {
  local platform_pattern="${1:-*/recipes/*/*.bicep}"  # Default to all platforms
  echo "Finding and publishing Bicep recipes with pattern: $platform_pattern"
  readarray -t bicep_recipes < <(find_recipe_files "$platform_pattern")

  if [[ ${#bicep_recipes[@]} -eq 0 ]]; then
    echo "No Bicep recipe files found for pattern: $platform_pattern"
    exit 0
  fi

  echo "Found ${#bicep_recipes[@]} Bicep recipes"

  # Publish all Bicep recipes
  for recipe_file in "${bicep_recipes[@]}"; do
    read -r root_folder resource_type platform_service file_name <<< "$(extract_recipe_info "$recipe_file")"
    
    recipe_name=$(basename "$recipe_file" .bicep)
    registry_path="localhost:51351/recipes/$resource_type/$platform_service/$recipe_name:latest"
    
    echo "Publishing Bicep recipe '$recipe_name' from $platform_service to registry: $registry_path"
    if rad bicep publish --file "$recipe_file" --target "br:$registry_path" --plain-http; then
      echo "✅ Successfully published Bicep recipe to registry"
    else
      echo "❌ Failed to publish Bicep recipe to registry"
      exit 1
    fi
  done

  echo "✅ All Bicep recipes published successfully"
}

# Register and test recipes (unified function for Bicep and Terraform)
test_recipes() {
  local template_kind="$1"
  local platform_filter="$2"  # Optional platform filter (e.g., "kubernetes", "azure")
  shift 2
  local recipes=("$@")
  
  if [[ ${#recipes[@]} -eq 0 ]]; then
    echo "No $template_kind recipes to test"
    return 0
  fi
  
  echo ""
  echo "🔄 Testing $template_kind recipes for platform: ${platform_filter:-all}..."
  
  # Group recipes by platform service
  declare -A platform_recipes
  for recipe_file in "${recipes[@]}"; do
    read -r root_folder resource_type platform_service file_name <<< "$(extract_recipe_info "$recipe_file")"
    
    # Skip if platform filter is specified and doesn't match
    if [[ -n "$platform_filter" && "$platform_service" != "$platform_filter" ]]; then
      echo "Skipping $platform_service recipe (filter: $platform_filter)"
      continue
    fi
    
    platform_key="$root_folder/$resource_type/$platform_service"
    if [[ "$template_kind" == "terraform" ]]; then
      # For Terraform, use the directory path
      recipe_path=$(dirname "$recipe_file")
    else
      # For Bicep, use the file path
      recipe_path="$recipe_file"
    fi
    
    if [[ -z "${platform_recipes[$platform_key]}" ]]; then
      platform_recipes[$platform_key]="$recipe_path"
    else
      platform_recipes[$platform_key]="${platform_recipes[$platform_key]} $recipe_path"
    fi
  done

  # Process each platform service
  for platform_key in "${!platform_recipes[@]}"; do
    IFS='/' read -r root_folder resource_type platform_service <<< "$platform_key"
    echo ""
    echo "🔄 Processing $template_kind recipe for: $platform_service ($root_folder/$resource_type)"
    
    # Get the Radius namespace
    radius_namespace=$(get_radius_namespace "$root_folder")

    # Unregister any existing default recipe for this resource type
    echo "Unregistering any existing default recipe for $radius_namespace/$resource_type"
    rad recipe unregister default --environment default --resource-type "$radius_namespace/$resource_type" || echo "No existing default recipe to unregister"

    # Register recipes based on type
    for recipe_path in ${platform_recipes[$platform_key]}; do
      if [[ "$template_kind" == "bicep" ]]; then
        # Bicep recipe registration
        recipe_name=$(basename "$recipe_path" .bicep)
        registry_path="localhost:51351/recipes/$resource_type/$platform_service/$recipe_name:latest"
        
        echo "Publishing Bicep recipe '$recipe_name' to registry: $registry_path"
        if rad bicep publish --file "$recipe_path" --target "br:$registry_path" --plain-http; then
          echo "✅ Successfully published Bicep recipe to registry"
        else
          echo "❌ Failed to publish Bicep recipe to registry"
          exit 1
        fi
        
        internal_registry_path="reciperegistry:5000/recipes/$resource_type/$platform_service/$recipe_name:latest"
        echo "Registering Bicep recipe 'default' for resource type '$radius_namespace/$resource_type'"
        template_path="$internal_registry_path"
        
      elif [[ "$template_kind" == "terraform" ]]; then
        # Terraform recipe registration
        # Use the same naming convention as the publishing step: resource_type-platform_service
        recipe_name="$resource_type-$platform_service"
        tf_namespace="radius-test-tf-module-server"
        deployment_name="tf-module-server"
        module_server_url="http://$deployment_name.$tf_namespace.svc.cluster.local/$recipe_name.zip"
        
        echo "Registering Terraform recipe 'default' for resource type '$radius_namespace/$resource_type'"
        echo "Using module URL: $module_server_url"
        template_path="$module_server_url"
      fi
      
      # Register the recipe
      if rad recipe register default --environment default --resource-type "$radius_namespace/$resource_type" --template-kind "$template_kind" --template-path "$template_path" --plain-http; then
        echo "✅ Successfully registered $template_kind recipe as default"
      else
        echo "❌ Failed to register $template_kind recipe as default"
        exit 1
      fi
    done
    
    # Deploy test application for this resource type
    test_app_path="$root_folder/$resource_type/test/app.bicep"
    deployment_name="test-${root_folder,,}-${platform_service}-${template_kind}-$(date +%s)"
    
    deploy_and_cleanup_test_app "$test_app_path" "$deployment_name" "for $platform_service ($template_kind recipe)"
    
    echo "✅ Completed testing $template_kind recipe for $platform_service"
  done
}