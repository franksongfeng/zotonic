.. _export_resource_content_type:

export_resource_content_type
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mod_export - Determine the mime type for the export. 


Type: 
    :ref:`notification-first`

Return: 
    ``{ok, "text/csv"})`` for the dispatch rule/id export.

``#export_resource_content_type{}`` properties:
    - dispatch: ``atom``
    - id: ``m_rsc:resource_id()|undefined``
