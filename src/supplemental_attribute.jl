function get_supplemental_attribute_associations(attribute::SupplementalAttribute)
    return get_internal(
        attribute,
    ).shared_system_references.supplemental_attribute_associations
end
