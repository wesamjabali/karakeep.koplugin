local EventListener = require('ui/widget/eventlistener')
local DataStorage = require('datastorage')
local _ = require('gettext')
local T = require('ffi/util').template
local logger = require('logger')

local Files = require('karakeep/shared/files')
local Notification = require('karakeep/shared/widgets/notification')

---@class BookmarksToFolder : EventListener
---@field ui UI Reference to UI for accessing registered modules
---@field settings Settings Plugin settings instance
local BookmarksToFolder = EventListener:extend({})

local DEFAULT_EXPORT_DIR = DataStorage:getDataDir() .. '/books/karakeep'

function BookmarksToFolder:getExportDir()
    local dir = self.settings and self.settings.export_dir
    if dir and dir ~= '' then
        return dir
    end
    return DEFAULT_EXPORT_DIR
end

function BookmarksToFolder:exportBookmarksToFolder()
    local NetworkMgr = require('ui/network/manager')
    if not NetworkMgr:isOnline() then
        Notification:error(_('Network is not available'))
        return
    end

    local export_dir = self:getExportDir()

    local ok, err = Files.createDirectories(export_dir)
    if not ok then
        Notification:error(_('Failed to create export directory'))
        return
    end

    local all_bookmarks = {}
    local cursor = nil

    local loading = Notification:info(_('Fetching bookmarks...'))

    while true do
        local query = {
            includeContent = true,
        }
        if cursor ~= nil then
            logger.dbg('[BookmarksToFolder] cursor type:', type(cursor), 'value:', cursor)
            query.cursor = cursor
        end

        local success, result, err = pcall(function()
            return self.ui.karakeep_api:listBookmarks({
                query = query,
            })
        end)

        if not success then
            loading:close()
            logger.err('[BookmarksToFolder] Lua error:', result)
            Notification:error(_('Failed to fetch bookmarks'))
            return
        end

        if not result then
            loading:close()
            local error_msg = err and err.message or _('Unknown error')
            if type(error_msg) ~= 'string' then
                error_msg = tostring(error_msg)
            end
            logger.err('[BookmarksToFolder] API error:', error_msg)
            Notification:error(error_msg)
            return
        end

        local bookmarks = result.bookmarks or {}
        for _, bm in ipairs(bookmarks) do
            table.insert(all_bookmarks, bm)
        end

        cursor = type(result.nextCursor) == "string" and result.nextCursor or nil
        logger.dbg('[BookmarksToFolder] nextCursor type:', type(cursor), 'value:', cursor)
        if not cursor then
            break
        end
    end

    loading:close()

    if #all_bookmarks == 0 then
        Notification:info(_('No non-archived bookmarks to export'))
        return
    end

    local saved = 0
    local errors = 0

    local saving = Notification:info(T(_('Saving %1 bookmarks...'), #all_bookmarks))

    for _, bm in ipairs(all_bookmarks) do
        local filename = self:sanitizeFileName(bm.title or bm.id) .. '.txt'
        local filepath = export_dir .. '/' .. filename

        local content = self:formatBookmark(bm)
        local write_ok, write_err = Files.writeFile(filepath, content)
        if write_ok then
            saved = saved + 1
        else
            errors = errors + 1
            logger.err('[BookmarksToFolder] Failed to write', filepath, write_err and write_err.message)
        end
    end

    saving:close()

    if saved > 0 then
        Notification:success(T(_('Saved %1 bookmarks to %2'), saved, export_dir))
    end
    if errors > 0 then
        Notification:warn(T(_('Failed to save %1 bookmarks'), errors))
    end
end

function BookmarksToFolder:sanitizeFileName(name)
    if not name or name == '' then
        return 'untitled'
    end
    local safe = name:gsub('[<>:"/\\|?*]', '_')
    safe = safe:gsub('%s+', ' ')
    safe = safe:match('^%s*(.-)%s*$') or safe
    if #safe == 0 then
        return 'untitled'
    end
    if #safe > 100 then
        safe = safe:sub(1, 100)
    end
    return safe
end

function BookmarksToFolder:formatBookmark(bm)
    local lines = {}

    table.insert(lines, 'Title: ' .. (bm.title or '(untitled)'))

    local content = bm.content or {}
    if content.type == 'link' then
        if content.url then
            table.insert(lines, 'URL: ' .. content.url)
        end
        if content.htmlContent then
            table.insert(lines, '')
            table.insert(lines, '---')
            table.insert(lines, content.htmlContent)
            table.insert(lines, '---')
        end
    elseif content.type == 'text' and content.text then
        table.insert(lines, '')
        table.insert(lines, '---')
        table.insert(lines, content.text)
        table.insert(lines, '---')
    end

    table.insert(lines, '')
    table.insert(lines, 'ID: ' .. bm.id)

    if bm.note and bm.note ~= '' then
        table.insert(lines, '')
        table.insert(lines, 'Note:')
        table.insert(lines, bm.note)
    end

    if bm.summary and bm.summary ~= '' then
        table.insert(lines, '')
        table.insert(lines, 'Summary:')
        table.insert(lines, bm.summary)
    end

    if bm.tags and #bm.tags > 0 then
        local tag_names = {}
        for _, tag in ipairs(bm.tags) do
            table.insert(tag_names, tag.name)
        end
        table.insert(lines, '')
        table.insert(lines, 'Tags: ' .. table.concat(tag_names, ', '))
    end

    table.insert(lines, '')
    table.insert(lines, 'Created: ' .. (bm.createdAt or 'unknown'))
    table.insert(lines, 'Updated: ' .. (bm.modifiedAt or 'unknown'))
    table.insert(lines, 'Favourited: ' .. tostring(bm.favourited or false))

    return table.concat(lines, '\n')
end

return BookmarksToFolder
