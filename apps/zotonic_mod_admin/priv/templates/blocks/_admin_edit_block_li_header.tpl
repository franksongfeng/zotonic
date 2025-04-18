{% extends "admin_edit_widget_i18n.tpl" %}

{% block widget_title %}
{_ Page block _}
<div class="widget-header-tools"></div>
{% endblock %}

{% block widget_show_minimized %}false{% endblock %}
{% block widget_id %}edit-block-{{ #block }}{% endblock %}
{% block widget_header %}{% endblock %}

{% block widget_content %}
<fieldset class="form">
    <div class="form-group label-floating">
    {% if id.is_editable %}
        <input class="form-control"
               type="text"
               id="block-{{name}}-header{{ lang_code_for_id }}"
               name="blocks[].header{{ lang_code_with_dollar }}"
               value="{{ blk.header|translation:lang_code }}"
               placeholder="{_ Header _} ({{ lang_code }})">
        <label>{_ Header _} ({{ lang_code }})</label>
    {% else %}
        <h3>{{ blk.header|translation:lang_code }}</h3>
    {% endif %}
    </div>
</fieldset>
{% endblock %}
