{% if menu or menu_id.is_visible %}
{% with id|menu_trail:menu_id as parents %}
    <ul id="{{ id_prefix }}navigation" class="{{ class }}">
    {% for mid, path, action in menu %}
        {% if mid %}
            {% if action==`down` %}
                <li class="dropdown{% if mid|member:parents %} active{% endif %}">
                    <a href="{{ mid.page_url }}" class="dropdown-toggle {{ mid.name }}" data-toggle="dropdown">
                        {{ mid.short_title|default:mid.title }} <b class="caret"></b></a>
                    <ul class="dropdown-menu">
            {% else %}
                <li class="{% if mid|member:parents %}active{% endif %}">
                    <a href="{{ mid.page_url }}" class="{{ mid.name }}{% if mid|member:parents %} active{% endif %}">
                        {{ mid.short_title|default:mid.title }}
                    </a>
                </li>
            {% endif %}
        {% else %}
            </ul></li>
        {% endif %}
    {% endfor %}
    {% include "_menu_extra.tpl" %}
    </ul>
{% endwith %}
{% endif %}
