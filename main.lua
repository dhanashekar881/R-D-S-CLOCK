require "import"
import "android.app.AlertDialog"
import "android.content.Context"
import "android.content.DialogInterface"
import "android.content.Intent"
import "android.net.Uri"
import "android.os.Build"
import "android.os.Handler"
import "android.os.Looper"
import "android.os.Vibrator"
import "android.os.VibrationEffect"
import "android.speech.RecognitionListener"
import "android.speech.RecognizerIntent"
import "android.speech.SpeechRecognizer"
import "android.text.Editable"
import "android.text.TextWatcher"
import "android.view.View"
import "android.view.ViewGroup"
import "android.view.WindowManager"
import "android.widget.AdapterView"
import "android.widget.ArrayAdapter"
import "android.widget.Button"
import "android.widget.EditText"
import "android.widget.LinearLayout"
import "android.widget.ListView"
import "android.widget.ScrollView"
import "android.widget.Spinner"
import "android.widget.TextView"
import "java.io.BufferedReader"
import "java.io.DataOutputStream"
import "java.io.InputStreamReader"
import "java.io.OutputStreamWriter"
import "java.lang.Runnable"
import "java.lang.Thread"
import "java.lang.System"
import "java.lang.StringBuilder"
import "java.net.HttpURLConnection"
import "java.net.URL"
import "java.net.URLEncoder"
import "java.util.ArrayList"
import "java.util.Collections"
import "java.util.Locale"
import "org.json.JSONArray"
import "org.json.JSONObject"

local mainHandler = Handler(Looper.getMainLooper())
local prefs = service.getSharedPreferences("RDSVoiceDictationSettings", Context.MODE_PRIVATE)

local function doVibrate(patternType)
  local isVibEnabled = prefs.getBoolean("vibration_feedback", true)
  if not isVibEnabled then return end

  pcall(function()
    local vibrator = service.getSystemService(Context.VIBRATOR_SERVICE)
    if not vibrator or not vibrator.hasVibrator() then return end

    if patternType == "start" then
      if Build.VERSION.SDK_INT >= 26 then
        vibrator.vibrate(VibrationEffect.createOneShot(50, VibrationEffect.DEFAULT_AMPLITUDE))
      else
        vibrator.vibrate(50)
      end
    elseif patternType == "success" then
      local pattern = {0, 60, 80, 60}
      if Build.VERSION.SDK_INT >= 26 then
        vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
      else
        vibrator.vibrate(pattern, -1)
      end
    elseif patternType == "error" then
      if Build.VERSION.SDK_INT >= 26 then
        vibrator.vibrate(VibrationEffect.createOneShot(300, VibrationEffect.DEFAULT_AMPLITUDE))
      else
        vibrator.vibrate(300)
      end
    end
  end)
end

local function prepareServiceDialog(dialog)
  local window = dialog.getWindow()
  if window then
    if Build.VERSION.SDK_INT >= 26 then
      window.setType(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY)
    elseif Build.VERSION.SDK_INT >= 22 then
      window.setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
    else
      window.setType(WindowManager.LayoutParams.TYPE_SYSTEM_ALERT)
    end
  end
end

local function cleanupRecognizer()
  _G.isRDSListening = false
  if _G.activeSpeechRecognizer then
    pcall(function()
      _G.activeSpeechRecognizer.cancel()
      _G.activeSpeechRecognizer.destroy()
    end)
    _G.activeSpeechRecognizer = nil
  end
end

----------------------------------------------------------------
----------------------------------------------------------------
local storagePath = os.getenv("EXTERNAL_STORAGE") or "/sdcard"
local dictFile = storagePath .. "/unique_typer_dual_dict.dat"

local normalDict = {}
local convertDict = {}
local dictLangs = {}

local function loadDictionary()
    normalDict = {}
    convertDict = {}
    dictLangs = {}

    pcall(function()
        local langsStr = tostring(prefs.getString("dict_added_langs", ""))
        if langsStr ~= "" then
            local jsonObj = JSONObject(langsStr)
            local keys = jsonObj.keys()
            while keys.hasNext() do
                local tag = tostring(keys.next())
                dictLangs[tag] = tostring(jsonObj.getString(tag))
            end
        end
    end)

    pcall(function()
        local content = prefs.getString("custom_dual_dict_json", "")
        if content == "" then
            local f = io.open(dictFile, "r")
            if f then
                content = f:read("*all")
                f:close()
            end
        end
        if content and content ~= "" then
            local rootObj = JSONObject(tostring(content))

            if rootObj.has("normal") then
                local normObj = rootObj.getJSONObject("normal")
                local nKeys = normObj.keys()
                while nKeys.hasNext() do
                    local langTag = tostring(nKeys.next())
                    normalDict[langTag] = {}
                    local langObj = normObj.getJSONObject(langTag)
                    local wKeys = langObj.keys()
                    while wKeys.hasNext() do
                        local w = tostring(wKeys.next())
                        normalDict[langTag][w] = tostring(langObj.getString(w))
                    end
                end
            end

            if rootObj.has("convert") then
                local convObj = rootObj.getJSONObject("convert")
                local cKeys = convObj.keys()
                while cKeys.hasNext() do
                    local langTag = tostring(cKeys.next())
                    convertDict[langTag] = {}
                    local langObj = convObj.getJSONObject(langTag)
                    local wKeys = langObj.keys()
                    while wKeys.hasNext() do
                        local w = tostring(wKeys.next())
                        convertDict[langTag][w] = tostring(langObj.getString(w))
                    end
                end
            end
        end
    end)
end

local function saveDictionaryLanguages()
    pcall(function()
        local jsonObj = JSONObject()
        for tag, name in pairs(dictLangs) do
            jsonObj.put(tostring(tag), tostring(name))
        end
        local editor = prefs.edit()
        editor.putString("dict_added_langs", jsonObj.toString())
        editor.apply()
    end)
end

local function saveDictionary()
    pcall(function()
        local rootObj = JSONObject()

        local normObj = JSONObject()
        for langKey, subTable in pairs(normalDict) do
            if type(subTable) == "table" then
                local subObj = JSONObject()
                for k, v in pairs(subTable) do
                    subObj.put(tostring(k), tostring(v))
                end
                normObj.put(tostring(langKey), subObj)
            end
        end
        rootObj.put("normal", normObj)

        local convObj = JSONObject()
        for langKey, subTable in pairs(convertDict) do
            if type(subTable) == "table" then
                local subObj = JSONObject()
                for k, v in pairs(subTable) do
                    subObj.put(tostring(k), tostring(v))
                end
                convObj.put(tostring(langKey), subObj)
            end
        end
        rootObj.put("convert", convObj)

        local str = rootObj.toString()
        local editor = prefs.edit()
        editor.putString("custom_dual_dict_json", str)
        editor.apply()

        local f = io.open(dictFile, "w")
        if f then
            f:write(str)
            f:close()
        end
    end)
end

local function addLanguageToDictionaryList(langName, langTag)
    if not langTag or langTag == "" then return end
    dictLangs[langTag] = langName
    normalDict[langTag] = normalDict[langTag] or {}
    convertDict[langTag] = convertDict[langTag] or {}
    saveDictionaryLanguages()
    saveDictionary()
end

local function addWordToSpecificDictionary(dictType, langTag, wrongWord, correctWord)
    if not langTag or not wrongWord or not correctWord or wrongWord == "" or correctWord == "" then
        return false
    end
    local targetTable = (dictType == "normal") and normalDict or convertDict
    targetTable[langTag] = targetTable[langTag] or {}
    targetTable[langTag][wrongWord] = correctWord
    saveDictionary()
    return true
end

loadDictionary()

----------------------------------------------------------------
----------------------------------------------------------------
local function getAllAvailableLanguages()
  local locales = Locale.getAvailableLocales()
  local map = {}
  local list = ArrayList()

  for i = 0, #locales - 1 do
    local loc = locales[i]
    local langCode = tostring(loc.getLanguage() or "")
    if langCode ~= "" then
      local countryCode = tostring(loc.getCountry() or "")
      local langName = tostring(loc.getDisplayLanguage(Locale.ENGLISH) or "")
      local countryName = tostring(loc.getDisplayCountry(Locale.ENGLISH) or "")

      local tag = langCode
      local displayStr = langName

      if countryCode ~= "" and countryName ~= "" then
        tag = langCode .. "-" .. countryCode
        displayStr = langName .. " (" .. countryName .. ") [" .. tag .. "]"
      else
        displayStr = langName .. " [" .. tag .. "]"
      end

      if not map[tag] and langName ~= "" then
        map[tag] = true
        list.add(displayStr)
      end
    end
  end

  Collections.sort(list)
  return list
end

local function getPinnedLanguages()
  local pinnedStr = prefs.getString("pinned_dictation_langs", "")
  local pins = {}
  for tag in pinnedStr:gmatch("[^,]+") do
    pins[tag] = true
  end
  return pins
end

local function savePinnedLanguages(pins)
  local list = {}
  for tag, _ in pairs(pins) do
    table.insert(list, tag)
  end
  local editor = prefs.edit()
  editor.putString("pinned_dictation_langs", table.concat(list, ","))
  editor.apply()
end

local function getOrganizedLanguages()
  local rawList = getAllAvailableLanguages()
  local pins = getPinnedLanguages()
  
  local pinnedItems = ArrayList()
  local normalItems = ArrayList()
  
  for i = 0, rawList.size() - 1 do
    local item = tostring(rawList.get(i))
    local tag = item:match("%[([%w%-_]+)%]$")
    if tag and pins[tag] then
      pinnedItems.add("馃搶 " .. item)
    else
      normalItems.add(item)
    end
  end
  
  Collections.sort(pinnedItems)
  Collections.sort(normalItems)
  
  local combined = ArrayList()
  for i = 0, pinnedItems.size() - 1 do
    combined.add(pinnedItems.get(i))
  end
  for i = 0, normalItems.size() - 1 do
    combined.add(normalItems.get(i))
  end
  return combined
end

local function openLanguageSearchDialog(titleText, currentSelectedTag, onSelectCallback)
  local allLangs = getOrganizedLanguages()
  local filteredList = ArrayList(allLangs)

  local layout = LinearLayout(service)
  layout.setOrientation(LinearLayout.VERTICAL)
  layout.setPadding(30, 20, 30, 20)

  local searchBox = EditText(service)
  searchBox.setHint("Search language (Long press for options)...")
  searchBox.setSingleLine(true)
  layout.addView(searchBox)

  local listView = ListView(service)
  local adapter = ArrayAdapter(service, android.R.layout.simple_list_item_1, filteredList)
  listView.setAdapter(adapter)

  local listParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1.0)
  listView.setLayoutParams(listParams)
  layout.addView(listView)

  local dialog = AlertDialog.Builder(service)
    .setTitle(titleText)
    .setView(layout)
    .setNegativeButton("Cancel", nil)
    .create()

  searchBox.addTextChangedListener(TextWatcher{
    beforeTextChanged = function(s, start, count, after) end,
    onTextChanged = function(s, start, before, count)
      local query = tostring(s):lower():match("^%s*(.-)%s*$")
      filteredList.clear()
      local freshList = getOrganizedLanguages()
      for i = 0, freshList.size() - 1 do
        local item = tostring(freshList.get(i))
        if query == "" or item:lower():find(query, 1, true) then
          filteredList.add(item)
        end
      end
      adapter.notifyDataSetChanged()
    end,
    afterTextChanged = function(s) end
  })

  listView.setOnItemClickListener(AdapterView.OnItemClickListener{
    onItemClick = function(parent, view, position, id)
      local selectedStr = tostring(filteredList.get(position))
      local tag = selectedStr:match("%[([%w%-_]+)%]$")
      local name = selectedStr:match("^(.-)%s*%[") or selectedStr
      name = name:gsub("^馃搶%s*", ""):match("^%s*(.-)%s*$")
      if tag and onSelectCallback then
        onSelectCallback(name, tag, selectedStr)
      end
      dialog.dismiss()
    end
  })

  listView.setOnItemLongClickListener(AdapterView.OnItemLongClickListener{
    onItemLongClick = function(parent, view, position, id)
      local selectedStr = tostring(filteredList.get(position))
      local tag = selectedStr:match("%[([%w%-_]+)%]$")
      local name = selectedStr:match("^(.-)%s*%[") or selectedStr
      name = name:gsub("^馃搶%s*", ""):match("^%s*(.-)%s*$")

      if tag then
        local pins = getPinnedLanguages()
        local isPinned = pins[tag]
        local pinOptionText = isPinned and "Unpin from Top" or "Pin to Top"

        local menuOptions = {
            "Add to Dictionary",
            pinOptionText
        }

        local menuList = ListView(service)
        menuList.setAdapter(ArrayAdapter(service, android.R.layout.simple_list_item_1, menuOptions))

        local menuDlg = AlertDialog.Builder(service)
          .setTitle(name .. " Options")
          .setView(menuList)
          .setNegativeButton("Cancel", nil)
          .create()

        menuList.setOnItemClickListener(AdapterView.OnItemClickListener{
          onItemClick = function(l, v, p, i)
            menuDlg.dismiss()
            local choice = menuOptions[p + 1]
            if choice == "Add to Dictionary" then
                addLanguageToDictionaryList(name, tag)
                doVibrate("success")
                service.speak(name .. " added to Dictionary")
            elseif choice == "Pin to Top" or choice == "Unpin from Top" then
                if pins[tag] then
                    pins[tag] = nil
                    service.speak("Unpinned " .. name)
                else
                    pins[tag] = true
                    service.speak("Pinned " .. name .. " to top")
                end
                savePinnedLanguages(pins)
                doVibrate("success")

                local query = tostring(searchBox.getText()):lower():match("^%s*(.-)%s*$")
                filteredList.clear()
                local freshList = getOrganizedLanguages()
                for idx = 0, freshList.size() - 1 do
                    local item = tostring(freshList.get(idx))
                    if query == "" or item:lower():find(query, 1, true) then
                        filteredList.add(item)
                    end
                end
                adapter.notifyDataSetChanged()
            end
          end
        })

        prepareServiceDialog(menuDlg)
        menuDlg.show()
        doVibrate("start")
        service.speak(name .. " Options, Popup window")
      end
      return true
    end
  })

  prepareServiceDialog(dialog)
  dialog.show()
end

----------------------------------------------------------------
----------------------------------------------------------------
local function openLanguageWordEditorDialog(dictType, langName, langTag)
    local typeLabel = (dictType == "normal") and "Normal Typing" or "English Converter"
    local targetTable = (dictType == "normal") and normalDict or convertDict

    local layout = LinearLayout(service)
    layout.setOrientation(LinearLayout.VERTICAL)
    layout.setPadding(30, 20, 30, 20)

    local wrongInput = EditText(service)
    wrongInput.setHint("Wrong word")
    wrongInput.setTextSize(16)
    layout.addView(wrongInput)

    local correctInput = EditText(service)
    correctInput.setHint("Correct word")
    correctInput.setTextSize(16)
    layout.addView(correctInput)

    local saveWordBtn = Button(service)
    saveWordBtn.setText("Save Word")
    layout.addView(saveWordBtn)

    local wordItems = ArrayList()
    local wordKeys = {}

    local function refreshWords()
        wordItems.clear()
        wordKeys = {}
        local subTable = targetTable[langTag]
        if subTable then
            for wrong, correct in pairs(subTable) do
                wordItems.add(wrong .. " -> " .. correct)
                table.insert(wordKeys, wrong)
            end
        end
    end

    refreshWords()

    local listView = ListView(service)
    local adapter = ArrayAdapter(service, android.R.layout.simple_list_item_1, wordItems)
    listView.setAdapter(adapter)
    local listParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 500)
    listView.setLayoutParams(listParams)
    layout.addView(listView)

    local dlg = AlertDialog.Builder(service)
        .setTitle(langName .. " (" .. typeLabel .. ")")
        .setView(layout)
        .setNegativeButton("Close", nil)
        .create()

    saveWordBtn.setOnClickListener{
        onClick = function(v)
            local w = tostring(wrongInput.getText()):match("^%s*(.-)%s*$")
            local c = tostring(correctInput.getText()):match("^%s*(.-)%s*$")
            if w ~= "" and c ~= "" then
                addWordToSpecificDictionary(dictType, langTag, w, c)
                wrongInput.setText("")
                correctInput.setText("")
                refreshWords()
                adapter.notifyDataSetChanged()
                doVibrate("success")
                service.speak("Saved " .. w .. " to " .. c)
            else
                service.speak("Please enter both words")
            end
        end
    }

    listView.setOnItemLongClickListener(AdapterView.OnItemLongClickListener{
        onItemLongClick = function(parent, view, position, id)
            local keyToRemove = wordKeys[position + 1]
            if keyToRemove and targetTable[langTag] then
                targetTable[langTag][keyToRemove] = nil
                saveDictionary()
                refreshWords()
                adapter.notifyDataSetChanged()
                doVibrate("success")
                service.speak("Deleted " .. keyToRemove)
            end
            return true
        end
    })

    prepareServiceDialog(dlg)
    dlg.show()
end

local function showDictionaryLanguagesDialog(dictType)
    local typeTitle = (dictType == "normal") and "Normal Typing Languages" or "English Converter Languages"
    local langListDisplay = ArrayList()
    local langTagMap = {}

    local function refreshLangList()
        langListDisplay.clear()
        langTagMap = {}
        local temp = {}
        for tag, name in pairs(dictLangs) do
            table.insert(temp, {tag = tag, name = name, display = name .. " [" .. tag .. "]"})
        end
        table.sort(temp, function(a, b) return a.display < b.display end)
        for _, item in ipairs(temp) do
            langListDisplay.add(item.display)
            table.insert(langTagMap, item)
        end
    end

    refreshLangList()

    if langListDisplay.size() == 0 then
        service.speak("No languages in dictionary. Long press a language in Dictation Language list and select Add to Dictionary.")
        return
    end

    local listView = ListView(service)
    local adapter = ArrayAdapter(service, android.R.layout.simple_list_item_1, langListDisplay)
    listView.setAdapter(adapter)

    local dlg = AlertDialog.Builder(service)
        .setTitle(typeTitle)
        .setView(listView)
        .setNegativeButton("Back", nil)
        .create()

    -- Tap to Open Word Editor
    listView.setOnItemClickListener(AdapterView.OnItemClickListener{
        onItemClick = function(parent, view, position, id)
            local selected = langTagMap[position + 1]
            if selected then
                dlg.dismiss()
                openLanguageWordEditorDialog(dictType, selected.name, selected.tag)
            end
        end
    })

    -- Long Press to Remove Language from Dictionary
    listView.setOnItemLongClickListener(AdapterView.OnItemLongClickListener{
        onItemLongClick = function(parent, view, position, id)
            local selected = langTagMap[position + 1]
            if selected then
                dictLangs[selected.tag] = nil
                if normalDict[selected.tag] then normalDict[selected.tag] = nil end
                if convertDict[selected.tag] then convertDict[selected.tag] = nil end
                saveDictionaryLanguages()
                saveDictionary()

                refreshLangList()
                adapter.notifyDataSetChanged()
                doVibrate("success")
                service.speak("Removed " .. selected.name .. " from Dictionary")

                if langListDisplay.size() == 0 then
                    dlg.dismiss()
                end
            end
            return true
        end
    })

    prepareServiceDialog(dlg)
    dlg.show()
end

----------------------------------------------------------------
----------------------------------------------------------------
local universalEntities = {
  {"喈曕喈熰瘝", "God"}, {"喈曕喈熰瘝!", "God"}, {"喈曕喈熰瘒", "God"},
  {"嗖椸簿嗖∴硩", "God"}, {"嗖︵硣嗖掂舶喑�", "Devaru"}, {"嗖︵硣嗖掂硩嗖班硜", "Devru"},
  {"喟椸熬喟∴睄", "God"}, {"喟︵眹喟掂眮喟∴眮", "Devudu"},
  {"啻椸祴啻∴祶", "God"}, {"啻︵祱啻掂磦", "Daivam"},
  {"啶椸啶�", "God"}, {"啶啶掂ぞ啶�", "Bhagwan"}, {"啶堗ざ啷嵿さ啶�", "Ishwar"},
  {"喈掂喈ㄠ喈畷喈班瘝 喈氞喁佮喁嵿喁嵿喈�", "Vinayagar Chaturthi"}, {"喈掂喈ㄠ喈畷 喈氞喁佮喁嵿喁嵿喈�", "Vinayagar Chaturthi"},
  {"喈曕喁囙畾 喈氞喁佮喁嵿喁嵿喈�", "Ganesh Chaturthi"}, {"喈曕喁囙喈� 喈氞喁佮喁嵿喁嵿喈�", "Ganesha Chaturthi"},
  {"喈曕喁囙 喈氞喁佮喁嵿喁嵿喈�", "Ganesh Chaturthi"}, {"喈氞喁佮喁嵿喁嵿喈�", "Chaturthi"},
  {"喟椸埃啾囙胺啾� 喟氞挨啾佮鞍啾嵿哎喟�", "Ganesh Chaturthi"}, {"喟掂翱喟ㄠ熬喟皶 喟氞暗喟苦挨喟�", "Vinayaka Chavithi"}, {"喟氞挨啾佮鞍啾嵿哎喟�", "Chaturthi"},
  {"嗖椸玻喑囙捕 嗖氞菠喑佮舶喑嵿播嗖�", "Ganesha Chaturthi"}, {"嗖椸玻喑囙捕 嗖灌铂喑嵿铂", "Ganesha Habba"}, {"嗖氞菠喑佮舶喑嵿播嗖�", "Chaturthi"},
  {"啶椸ぃ啷囙ざ 啶氞い啷佮ぐ啷嵿ぅ啷€", "Ganesh Chaturthi"}, {"啶氞い啷佮ぐ啷嵿ぅ啷€", "Chaturthi"},
  {"喈曕喈班瘉喈粪瘝喈� 喈溹瘑喈喁嵿喈�", "Krishna Jayanthi"}, {"喈曕喈班瘉喈粪瘝喈｀ 喈溹瘑喈喁嵿喈�", "Krishna Jayanthi"},
  {"喈曕喈班瘉喈粪瘝喈� 喈溹瘑喈┼瘝喈喈粪瘝喈熰喈�", "Krishna Janmashtami"}, {"喈曕喈班瘉喈粪瘝喈｀ 喈溹瘑喈┼瘝喈喈粪瘝喈熰喈�", "Krishna Janmashtami"},
  {"喈溹瘑喈┼瘝喈喈粪瘝喈熰喈�", "Janmashtami"}, {"喈曕瘚喈曕瘉喈侧喈粪瘝喈熰喈�", "Gokulashtami"},
  {"喈掂喈溹喈む畾喈", "Vijayadashami"}, {"喈掂喈溹 喈む畾喈", "Vijayadashami"},
  {"喈嗋喁佮 喈瘋喈溹瘓", "Ayudha Pooja"}, {"喈嗋喁佮喈瘋喈溹瘓", "Ayudha Pooja"},
  {"喈氞喈膏瘝喈掂喈� 喈瘋喈溹瘓", "Saraswathi Pooja"}, {"喈ㄠ喈班喈む瘝喈む喈班", "Navarathri"},
  {"喈む瘈喈喈掂喈�", "Deepavali"}, {"喈む喈掂喈赤", "Diwali"},
  {"喈瘖喈權瘝喈曕喁�", "Pongal"}, {"喈む瘓喈瘝喈瘖喈權瘝喈曕喁�", "Thai Pongal"},
  {"喈喈熰瘝喈熰瘉喈瘝喈瘖喈權瘝喈曕喁�", "Mattu Pongal"}, {"喈曕喈｀瘉喈瘝 喈瘖喈權瘝喈曕喁�", "Kaanum Pongal"},
  {"喈氞畽喁嵿畷喈班喈ㄠ瘝喈む", "Sankranti"}, {"喈瘚喈曕", "Bhogi"},
  {"喈む喈苦喁� 喈瘉喈む瘝喈む喈｀瘝喈熰瘉", "Tamil New Year"}, {"喈夃畷喈距喈�", "Ugadi"},
  {"喈撪喈瘝", "Onam"}, {"喈掂喈粪瘉", "Vishu"},
  {"喈曕喈编喈膏瘝喈む瘉喈喁�", "Christmas"}, {"喈瘉喈む瘝喈む喈｀瘝喈熰瘉", "New Year"},
  {"喈班喁嵿疁喈距喁�", "Ramzan"}, {"喈堗喁� 喈瘉喈喈班畷喁�", "Eid Mubarak"}, {"喈班喈侧喈┼瘝", "Ramadan"},
  {"喈喈熰喈庎畠喈瘝", ".pdf"}, {"喈庎喁嵿喈�3", ".mp3"}, {"喈庎喁嵿喈�4", ".mp4"},
  {"喈溹喈瘝", ".zip"}, {"喈班喈班瘝", ".rar"}, {"喈忇喈苦畷喁�", ".apk"},
  {"喈溹瘒喈喈溹", ".jpg"}, {"喈喈庎喁嵿疁喈�", ".png"}, {"喈熰喈庎畷喁嵿喁嵿疅喈�", ".txt"},
  {"喈曕瘚喈熰喈權瘝", "coding"}, {"喈瘝喈班瘚喈曕瘝喈班喈喈權瘝", "programming"},
  {"喈嗋喁嵿疅喁嵿喈距喁嵿疅喁�", "Android"}, {"喈侧瘉喈掂", "Lua"}, {"喈瘓喈む喈┼瘝", "Python"},
  {"喈氞喈班瘝", "Sir"}, {"喈瘒喈熰喁�", "Madam"}, {"喈喈膏瘝喈熰喁�", "Mr."},
  {"喈呧畽喁嵿畷喈苦喁�", "Uncle"}, {"喈嗋喁嵿疅喁嵿疅喈�", "Aunty"}, {"喈喈班喈班瘝", "brother"}, {"喈氞喈膏瘝喈熰喁�", "sister"},
  {"喈掂喈曕瘝喈曕喁�", "Vanakkam"}, {"喈ㄠ喁嵿喈班瘝喈曕喁�", "nanbargale"},
  {"喈曕瘉喈熰瘝 喈喈班瘝喈┼喈權瘝", "Good morning"}, {"喈曕瘉喈熰瘝 喈ㄠ瘓喈熰瘝", "Good night"},
  {"喈む瘒喈權瘝喈曕瘝喈膏瘝", "thanks"}, {"喈掂瘑喈侧瘝喈曕喁�", "welcome"}, {"喈瘝喈赤瘈喈膏瘝", "please"},
  {"喈灌喁�", "hello"}, {"喈灌喈瘝", "hi"}, {"喈瘝喈班瘚", "bro"}, {"喈氞喈膏瘝", "sis"}
}

local function formatCurrencyAndNumbersAll(text)
  if not text or text == "" then return "" end
  text = text:gsub("(%d+)%s*喈班瘋喈喈瘝", "Rs. %1")
  text = text:gsub("喈班瘋喈喈瘝%s*(%d+)", "Rs. %1")
  text = text:gsub("(%d+)%s*喈班瘋喈", "Rs. %1")
  text = text:gsub("喈班瘋喈%s*(%d+)", "Rs. %1")
  return text
end

local function cleanDiacriticsUniversal(text)
  if not text or text == "" then return "" end
  local diacritics = {
    ["膩"]="aa", ["谩"]="a", ["菐"]="a", ["脿"]="a", ["芒"]="a",
    ["墨"]="ee", ["铆"]="i", ["菒"]="i", ["矛"]="i", ["卯"]="i",
    ["奴"]="oo", ["煤"]="u", ["菙"]="u", ["霉"]="u", ["没"]="u",
    ["膿"]="e", ["茅"]="e", ["臎"]="e", ["猫"]="e", ["锚"]="e",
    ["艒"]="o", ["贸"]="o", ["菕"]="o", ["貌"]="o", ["么"]="o"
  }
  for k, v in pairs(diacritics) do
    text = text:gsub(k, v)
  end
  return text
end

local function applyDictionaryWords(text, langCode, dictType)
    local isDictEnabled = prefs.getBoolean("dictionary_enabled", true)
    if not isDictEnabled then return text end
    if not text or text == "" or not langCode then return text end

    local targetTable = (dictType == "normal") and normalDict or convertDict
    local subTable = targetTable[langCode]
    if not subTable then return text end

    for wrongWord, correctWord in pairs(subTable) do
        local escapedWrong = wrongWord:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        text = (" " .. text .. " "):gsub("(%s)" .. escapedWrong .. "(%s)", "%1" .. correctWord .. "%2"):sub(2, -2)
        if text:lower() == wrongWord:lower() then
            text = correctWord
        end
    end
    return text
end

local function smartTransliterateUniversal(sourceText, srcLang)
  if not sourceText or sourceText == "" then return "" end
  
  local processed = applyDictionaryWords(sourceText, srcLang, "convert")

  local shortLang = srcLang:match("^([%a]+)") or srcLang
  if shortLang == "en" then return processed end

  for _, pair in ipairs(universalEntities) do
    processed = processed:gsub(pair[1], pair[2])
  end
  processed = formatCurrencyAndNumbersAll(processed)

  local romanizedText = nil
  local success1, result1 = pcall(function()
    local encodedText = URLEncoder.encode(processed, "UTF-8")
    local urlStr = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=" .. shortLang .. "&tl=en&dt=rm&q=" .. encodedText
    local url = URL(urlStr)
    local conn = url.openConnection()
    conn.setRequestMethod("GET")
    conn.setRequestProperty("User-Agent", "Mozilla/5.0")
    conn.setConnectTimeout(4500)
    conn.setReadTimeout(4500)

    if conn.getResponseCode() ~= 200 then
      conn.disconnect()
      return nil
    end

    local reader = BufferedReader(InputStreamReader(conn.getInputStream(), "UTF-8"))
    local response = ""
    local line = reader.readLine()
    while line ~= nil do
      response = response .. line
      line = reader.readLine()
    end
    reader.close()
    conn.disconnect()

    local jsonArray = JSONArray(response)
    local fullRoman = ""
    if jsonArray.length() > 0 and not jsonArray.isNull(0) then
      local sentencesArray = jsonArray.getJSONArray(0)
      for i = 0, sentencesArray.length() - 1 do
        local detailArray = sentencesArray.getJSONArray(i)
        local rPart = ""
        if detailArray.length() >= 3 and not detailArray.isNull(2) then
          rPart = detailArray.getString(2)
        elseif detailArray.length() >= 4 and not detailArray.isNull(3) then
          rPart = detailArray.getString(3)
        end
        if rPart ~= "" then
          fullRoman = fullRoman .. rPart
        end
      end
    end
    if fullRoman ~= "" then return fullRoman end
    return nil
  end)

  if success1 and result1 and result1 ~= "" then
    romanizedText = result1
  else
    romanizedText = processed
  end

  local cleaned = cleanDiacriticsUniversal(romanizedText)
  return applyDictionaryWords(cleaned, srcLang, "convert")
end

----------------------------------------------------------------
----------------------------------------------------------------
local GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/"
local DEFAULT_GEMINI_MODEL = "gemini-2.5-flash"
local FALLBACK_GEMINI_MODELS = {
  "gemini-2.5-flash",
  "gemini-2.5-flash-lite",
  "gemini-2.5-pro",
  "gemini-2.0-flash"
}

local function trimStr(s)
  s = tostring(s or "")
  return (s:match("^%s*(.-)%s*$"))
end

-- Returns: httpStatusCode, responseBody   (code = -1 means network failure)
local function geminiHttp(method, path, apiKey, bodyStr, readTimeoutMs)
  local ok, code, resp = pcall(function()
    local url = URL(GEMINI_BASE .. path)
    local conn = url.openConnection()
    conn.setRequestMethod(method)
    conn.setRequestProperty("x-goog-api-key", apiKey)
    conn.setRequestProperty("Content-Type", "application/json; charset=UTF-8")
    conn.setRequestProperty("User-Agent", "Mozilla/5.0")
    conn.setConnectTimeout(5000)
    conn.setReadTimeout(readTimeoutMs or 20000)

    if bodyStr then
      conn.setDoOutput(true)
      local writer = OutputStreamWriter(conn.getOutputStream(), "UTF-8")
      writer.write(tostring(bodyStr))
      writer.flush()
      writer.close()
    end

    local statusCode = conn.getResponseCode()
    local stream = nil
    if statusCode >= 400 then
      stream = conn.getErrorStream()
    else
      stream = conn.getInputStream()
    end

    local text = ""
    if stream then
      local reader = BufferedReader(InputStreamReader(stream, "UTF-8"))
      local sb = StringBuilder()
      local line = reader.readLine()
      while line ~= nil do
        sb.append(line)
        line = reader.readLine()
      end
      reader.close()
      text = tostring(sb.toString())
    end
    return statusCode, text
  end)

  if not ok then
    return -1, tostring(code)
  end
  return code, resp
end

local function parseGeminiError(resp)
  local status = ""
  local message = ""
  pcall(function()
    local obj = JSONObject(resp)
    local e = obj.optJSONObject("error")
    if e then
      message = tostring(e.optString("message", ""))
      status = tostring(e.optString("status", ""))
    end
  end)
  return status, message
end

local function describeGeminiError(code, resp, model)
  if code == -1 then
    return "Network error. Please check your internet connection."
  end

  local status, message = parseGeminiError(resp)
  local low = message:lower()
  local shortMsg = message:sub(1, 160)

  if code == 429 then
    return "Quota exceeded or too many requests. Please wait and try again, or check your quota in Google AI Studio."
  elseif code == 400 then
    if low:find("expired", 1, true) then
      return "API key expired. Please create or renew the key."
    elseif low:find("api key not valid", 1, true) or low:find("api_key_invalid", 1, true) or low:find("api key", 1, true) then
      return "Invalid API key. Please check the key."
    end
    return "Bad request. " .. shortMsg
  elseif code == 401 or code == 403 then
    if low:find("expired", 1, true) then
      return "API key expired. Please create or renew the key."
    elseif low:find("leaked", 1, true) then
      return "This API key was reported as leaked and is blocked. Please create a new key."
    end
    return "API key rejected or permission denied. " .. shortMsg
  elseif code == 404 then
    return "Model " .. tostring(model) .. " not found or not available for this key. Please choose another model."
  elseif code >= 500 then
    return "Google server error " .. tostring(code) .. ". " .. shortMsg
  end
  return "Error " .. tostring(code) .. ". " .. shortMsg
end

-- Returns: sortedModelIdList (Lua table) or nil, errorMessage
local function fetchGeminiModels(apiKey)
  local code, resp = geminiHttp("GET", "models?pageSize=1000", apiKey, nil, 15000)
  if code ~= 200 then
    return nil, describeGeminiError(code, resp, "")
  end

  local ids = {}
  local seen = {}
  local parsed = pcall(function()
    local obj = JSONObject(resp)
    local arr = obj.optJSONArray("models")
    if not arr then return end

    local blocked = {"embedding", "tts", "image", "live", "audio", "robotics", "computer-use", "aqa", "imagen", "veo", "native"}

    for i = 0, arr.length() - 1 do
      local m = arr.getJSONObject(i)
      local name = tostring(m.optString("name", ""))
      local id = (name:gsub("^models/", ""))

      local supports = false
      local methods = m.optJSONArray("supportedGenerationMethods")
      if methods then
        for j = 0, methods.length() - 1 do
          if tostring(methods.getString(j)) == "generateContent" then
            supports = true
          end
        end
      end

      if supports and id:find("^gemini") and not seen[id] then
        local skip = false
        for _, word in ipairs(blocked) do
          if id:find(word, 1, true) then skip = true end
        end
        if not skip then
          seen[id] = true
          table.insert(ids, id)
        end
      end
    end
  end)

  if not parsed or #ids == 0 then
    return nil, "No Gemini models found for this key."
  end

  local function score(id)
    if id:find("flash", 1, true) and not id:find("lite", 1, true) then return 0 end
    if id:find("lite", 1, true) then return 1 end
    return 2
  end

  table.sort(ids, function(a, b)
    local sa, sb = score(a), score(b)
    if sa ~= sb then return sa < sb end
    return a > b
  end)

  return ids, nil
end

-- Returns: success(boolean), message(string)
local function testGeminiKey(apiKey, model)
  local body = '{"contents":[{"parts":[{"text":"Reply with the single word OK"}]}]}'
  local code, resp = geminiHttp("POST", "models/" .. model .. ":generateContent", apiKey, body, 20000)
  if code == 200 then
    return true, "API is working successfully. Model " .. model .. " is available. API key is valid and not expired, and quota is not exceeded right now."
  end
  return false, describeGeminiError(code, resp, model)
end

local function warmUpGemini()
  if not prefs.getBoolean("ai_typing_enabled", false) then return end
  local apiKey = trimStr(prefs.getString("gemini_api_key", ""))
  if apiKey == "" then return end
  local model = trimStr(prefs.getString("gemini_model", DEFAULT_GEMINI_MODEL))
  if model == "" then model = DEFAULT_GEMINI_MODEL end

  Thread(Runnable{
    run = function()
      pcall(function()
        geminiHttp("GET", "models/" .. model, apiKey, nil, 6000)
      end)
    end
  }).start()
end

local function getLanguageEnglishName(langTag)
  local name = tostring(langTag)
  pcall(function()
    local loc = Locale.forLanguageTag(tostring(langTag))
    local dn = tostring(loc.getDisplayLanguage(Locale.ENGLISH))
    if dn ~= "" then name = dn end
  end)
  return name
end

-- Returns: correctedText or nil, errorMessage
local function geminiProcess(spokenText, srcLang, tgtLang, doTranslate, doConvert)
  local apiKey = trimStr(prefs.getString("gemini_api_key", ""))
  local model = trimStr(prefs.getString("gemini_model", DEFAULT_GEMINI_MODEL))
  if apiKey == "" then return nil, "API key is not set." end
  if model == "" then model = DEFAULT_GEMINI_MODEL end
  if not spokenText or trimStr(spokenText) == "" then return nil, "Empty text." end

  local srcShort = tostring(srcLang):match("^([%a]+)") or tostring(srcLang)
  local convertMode = (not doTranslate) and doConvert and (srcShort ~= "en")

  local inputText = spokenText
  local instruction = ""

  if doTranslate then
    local tgtName = getLanguageEnglishName(tgtLang)
    instruction = "You are a voice dictation post-processor. The user text was produced by speech recognition. " ..
      "Translate it into " .. tgtName .. " with perfect grammar, spelling, capitalization and natural punctuation " ..
      "(commas, full stops, question marks). Do not add or remove information. " ..
      "Output ONLY the final text, with no quotes, notes, labels or explanations."
  elseif convertMode then
    inputText = applyDictionaryWords(spokenText, srcLang, "convert")
    for _, pair in ipairs(universalEntities) do
      inputText = inputText:gsub(pair[1], pair[2])
    end
    inputText = formatCurrencyAndNumbersAll(inputText)

    local srcName = getLanguageEnglishName(srcLang)
    instruction = "You are a voice dictation post-processor. The user text was produced by speech recognition in " .. srcName .. ". " ..
      "Rewrite it using English (Latin) letters only, the way people type " .. srcName .. " in English letters (transliteration / Romanization). " ..
      "Do NOT translate the meaning into English words; keep the same words as pronounced. " ..
      "Words that are already English, names, numbers, file extensions and symbols must stay as normal English. " ..
      "Use natural simple spelling without special accent marks. Fix grammar and wrongly recognized words using context, " ..
      "and add proper punctuation (commas, full stops, question marks) and capitalization. " ..
      "Do not add or remove information. " ..
      "Output ONLY the final text, with no quotes, notes, labels or explanations."
  else
    inputText = applyDictionaryWords(spokenText, srcLang, "normal")
    local srcName = getLanguageEnglishName(srcLang)
    instruction = "You are a voice dictation post-processor. The user text was produced by speech recognition in " .. srcName .. ". " ..
      "Correct all grammar and spelling mistakes, fix wrongly recognized words using context, and add proper punctuation " ..
      "(commas, full stops, question marks) and capitalization. Keep the same language and script as the input and do NOT translate. " ..
      "Do not add or remove information. " ..
      "Output ONLY the corrected text, with no quotes, notes, labels or explanations."
  end

  local emojiOn = prefs.getBoolean("use_emoji", false)
  local level = tostring(prefs.getString("emoji_level", "Medium Emoji"))
  -- Mode selection controls both AI and normal typing. Do not use a hard-coded list of names, fruits, brands or products.
  if level == "None" then
    instruction = instruction .. " STRICT OUTPUT RULE: preserve the spoken wording and existing punctuation exactly; do not add, remove or change any punctuation, and do not add emojis. Do not infer or append anything."
  elseif level == "Punctuation Only" or not emojiOn then
    instruction = instruction .. " Add natural, accurate punctuation throughout the text, including commas between items in spoken option/list sequences and question marks at genuine questions. Do not add any emojis. Preserve all names, brands, fruit names, product names and list items exactly as recognized; do not invent a word dictionary or replace names."
  else
    local density = ""
    if level == "Low Emoji Typing" or level == "Low" then
      density = "LOW EMOJI MODE: Add at most one highly relevant emoji at the END of each sentence, after its punctuation. Never put emojis at the beginning or between words. Skip an emoji if it does not fit the sentence."
    elseif level == "High Emoji" or level == "High" then
      density = "HIGH EMOJI MODE: Use clearly more emojis than Medium, while keeping text readable. Add about 2 relevant, familiar emojis per meaningful phrase/clause, and up to 3 for a longer phrase with distinct ideas. Place them at natural phrase boundaries (beginning, middle only for a long phrase, and/or end), never after every word. Avoid chains of repeated/decorative emojis, flags, skin-tone modifiers, ZWJ sequences, and obscure emojis. Prefer common, recognizable emojis that match the meaning. Preserve grammar, punctuation, and clear spacing for screen readers."
    else
      density = "MEDIUM EMOJI MODE: Add one relevant, familiar emoji for each meaningful phrase/clause, not each word. For example, in 'Hello friends, how are you? I am fine.' use one emoji after 'Hello friends' and one after 'how are you?'. Split at natural phrase boundaries such as commas and sentence endings. Do not clutter the text, repeat emojis, or add decorative symbols. Preserve natural grammar and punctuation and leave clear spaces for screen readers."
    end
    instruction = instruction .. " Add natural punctuation throughout, including commas between spoken options in lists and question marks for genuine questions. " .. density .. " Select only standard, familiar Unicode emoji that directly match the meaning of the whole phrase, not each individual word. Prefer simple emoji (for example, 馃檹, 馃槉, 馃巶, 馃崕, 馃殫) and avoid ornamental symbols, emoji chains, duplicate emoji, or confusing combinations. Keep emoji counts strictly proportional to the selected LOW/MEDIUM/HIGH preference. Preserve names and list items exactly; do not use a hard-coded dictionary, invent content, or translate the text. Output only the final text."
  end

  local bodyHead = '{"systemInstruction":{"parts":[{"text":' .. tostring(JSONObject.quote(instruction)) .. '}]},' ..
    '"contents":[{"role":"user","parts":[{"text":' .. tostring(JSONObject.quote(inputText)) .. '}]}],'

  local function bodyFor(thinkOff)
    if thinkOff then
      return bodyHead .. '"generationConfig":{"temperature":0.2,"thinkingConfig":{"thinkingBudget":0}}}'
    end
    return bodyHead .. '"generationConfig":{"temperature":0.2}}'
  end

  local function supportsThinkingOff(m)
    return m:find("2.5-flash", 1, true) ~= nil
  end

  _G.geminiBadModels = _G.geminiBadModels or {}
  local nowSec = os.time()

  local allModels = {}
  local seenModels = {}
  local function addModel(m)
    m = trimStr(m)
    if m ~= "" and not seenModels[m] then
      seenModels[m] = true
      table.insert(allModels, m)
    end
  end

  addModel(model)
  local cached = tostring(prefs.getString("gemini_models_cache", ""))
  for m in cached:gmatch("[^,]+") do addModel(m) end
  for _, m in ipairs({"gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash", "gemini-flash-latest", "gemini-flash-lite-latest"}) do
    addModel(m)
  end

  local tryModels = {}
  for _, m in ipairs(allModels) do
    local t = _G.geminiBadModels[m]
    if not (t and (nowSec - t) < 600) then
      table.insert(tryModels, m)
    end
    if #tryModels >= 4 then break end
  end
  if #tryModels == 0 then
    _G.geminiBadModels = {}
    for i, m in ipairs(allModels) do
      if i <= 4 then table.insert(tryModels, m) end
    end
  end

  local code, resp = -1, ""
  local lastErr = "Unknown error."
  local done = false
  local usedModel = model
  for _, tm in ipairs(tryModels) do
    local thinkOff = supportsThinkingOff(tm)
    for attempt = 1, 3 do
      code, resp = geminiHttp("POST", "models/" .. tm .. ":generateContent", apiKey, bodyFor(thinkOff), 15000)
      if code == 200 then
        done = true
        usedModel = tm
        break
      end
      if code == 400 and thinkOff then
        local _, em400 = parseGeminiError(resp)
        if em400:lower():find("thinking", 1, true) then
          thinkOff = false
        else
          break
        end
      elseif code == 500 or code == 502 or code == 503 or code == 504 then
        Thread.sleep(300)
      else
        break
      end
    end
    if done then break end

    lastErr = describeGeminiError(code, resp, tm)
    if code == 429 or code == 404 then
      _G.geminiBadModels[tm] = os.time()
    end

    local stopNow = false
    if code == -1 or code == 401 or code == 403 then
      stopNow = true
    elseif code == 400 then
      local _, em = parseGeminiError(resp)
      if em:lower():find("api key", 1, true) then stopNow = true end
    end
    if stopNow then break end
  end
  if not done then
    return nil, lastErr
  end

  local resultText = ""
  pcall(function()
    local obj = JSONObject(resp)
    local cands = obj.optJSONArray("candidates")
    if cands and cands.length() > 0 then
      local cand = cands.getJSONObject(0)
      local content = cand.optJSONObject("content")
      if content then
        local parts = content.optJSONArray("parts")
        if parts then
          for j = 0, parts.length() - 1 do
            local part = parts.getJSONObject(j)
            resultText = resultText .. tostring(part.optString("text", ""))
          end
        end
      end
    end
  end)

  resultText = trimStr(resultText)
  if resultText == "" then
    return nil, "Gemini returned no text."
  end
  if convertMode then
    resultText = trimStr(applyDictionaryWords(resultText, srcLang, "convert"))
  end
  return resultText, nil, usedModel
end

----------------------------------------------------------------
-- 4A-2. GROQ API (Models / Test / Voice Typing)
----------------------------------------------------------------
local GROQ_BASE = "https://api.groq.com/openai/v1/"
local DEFAULT_GROQ_MODEL = "openai/gpt-oss-20b"
local FALLBACK_GROQ_MODELS = {
  "openai/gpt-oss-20b",
  "llama-3.1-8b-instant",
  "openai/gpt-oss-120b",
  "llama-3.3-70b-versatile"
}

local function groqHttp(method, path, apiKey, bodyStr, readTimeoutMs)
  local ok, code, resp = pcall(function()
    local conn = URL(GROQ_BASE .. path).openConnection()
    conn.setRequestMethod(method)
    conn.setRequestProperty("Authorization", "Bearer " .. apiKey)
    conn.setRequestProperty("Content-Type", "application/json; charset=UTF-8")
    conn.setRequestProperty("Accept", "application/json")
    conn.setConnectTimeout(5000)
    conn.setReadTimeout(readTimeoutMs or 15000)
    if bodyStr then
      conn.setDoOutput(true)
      local writer = OutputStreamWriter(conn.getOutputStream(), "UTF-8")
      writer.write(tostring(bodyStr))
      writer.flush()
      writer.close()
    end
    local statusCode = conn.getResponseCode()
    local stream = nil
    if statusCode >= 400 then
      stream = conn.getErrorStream()
    else
      stream = conn.getInputStream()
    end
    local result = ""
    if stream then
      local reader = BufferedReader(InputStreamReader(stream, "UTF-8"))
      local sb = StringBuilder()
      local line = reader.readLine()
      while line ~= nil do
        sb.append(line)
        line = reader.readLine()
      end
      reader.close()
      result = tostring(sb.toString())
    end
    return statusCode, result
  end)
  if not ok then return -1, tostring(code) end
  return code, resp
end

local function describeGroqError(code, resp, model)
  if code == -1 then return "Network error while contacting Groq. Check your internet connection." end
  local message = ""
  pcall(function()
    local obj = JSONObject(resp)
    local e = obj.optJSONObject("error")
    if e then message = tostring(e.optString("message", "")) end
  end)
  local low = message:lower()
  if code == 401 or code == 403 then
    return "Groq API key is invalid or access is denied. Check your Groq API key."
  elseif code == 429 then
    return "Groq quota or rate limit exceeded. Try another available model or check your Groq limits."
  elseif code == 404 then
    return "Groq model " .. tostring(model) .. " is unavailable. Refresh Models and choose another model."
  elseif code >= 500 then
    return "Groq server error " .. tostring(code) .. ". Please retry."
  elseif low:find("model", 1, true) and low:find("decommission", 1, true) then
    return "This Groq model is no longer available. Refresh Models."
  end
  if message == "" then message = tostring(resp or "") end
  return "Groq error " .. tostring(code) .. ". " .. message:sub(1, 180)
end

local function fetchGroqModels(apiKey)
  local code, resp = groqHttp("GET", "models", apiKey, nil, 12000)
  if code ~= 200 then return nil, describeGroqError(code, resp, "") end
  local ids, seen = {}, {}
  local ok = pcall(function()
    local obj = JSONObject(resp)
    local arr = obj.optJSONArray("data")
    if not arr then return end
    local blocked = {"whisper", "audio", "speech", "embedding", "guard", "orpheus", "tts"}
    for i = 0, arr.length() - 1 do
      local m = arr.getJSONObject(i)
      local id = trimStr(m.optString("id", ""))
      local active = m.optBoolean("active", true)
      local lower = id:lower()
      local skip = id == ""
      for _, word in ipairs(blocked) do
        if lower:find(word, 1, true) then skip = true end
      end
      if active and not skip and not seen[id] then
        seen[id] = true
        table.insert(ids, id)
      end
    end
  end)
  if not ok or #ids == 0 then return nil, "No usable Groq text models were returned for this API key." end
  local function score(id)
    local l = id:lower()
    if l:find("8b-instant", 1, true) then return 0 end
    if l:find("gpt-oss-20b", 1, true) then return 1 end
    if l:find("70b", 1, true) then return 3 end
    if l:find("120b", 1, true) then return 4 end
    return 2
  end
  table.sort(ids, function(a, b)
    local sa, sb = score(a), score(b)
    if sa ~= sb then return sa < sb end
    return a < b
  end)
  return ids, nil
end

local function testGroqKey(apiKey, model)
  local body = '{"messages":[{"role":"user","content":"Reply with the single word OK"}],"model":' ..
    tostring(JSONObject.quote(model)) .. ',"temperature":0,"max_tokens":8}'
  local code, resp = groqHttp("POST", "chat/completions", apiKey, body, 15000)
  if code == 200 then return true, "Groq API is working. Model " .. model .. " is available." end
  return false, describeGroqError(code, resp, model)
end

local function groqProcess(spokenText, srcLang, tgtLang, doTranslate, doConvert)
  local apiKey = trimStr(prefs.getString("groq_api_key", ""))
  local model = trimStr(prefs.getString("groq_model", DEFAULT_GROQ_MODEL))
  if apiKey == "" then return nil, "Groq API key is not set." end
  if model == "" then model = DEFAULT_GROQ_MODEL end
  if not spokenText or trimStr(spokenText) == "" then return nil, "Empty text." end

  local srcShort = tostring(srcLang):match("^([%a]+)") or tostring(srcLang)
  local convertMode = (not doTranslate) and doConvert and (srcShort ~= "en")
  local inputText = spokenText
  local instruction = ""

  if doTranslate then
    local tgtName = getLanguageEnglishName(tgtLang)
    instruction = "You are a voice dictation post-processor. Translate the speech-recognition text into " .. tgtName ..
      " with correct grammar, spelling, capitalization and natural punctuation. Do not add or remove information. Output ONLY the final text."
  elseif convertMode then
    inputText = applyDictionaryWords(spokenText, srcLang, "convert")
    for _, pair in ipairs(universalEntities) do inputText = inputText:gsub(pair[1], pair[2]) end
    inputText = formatCurrencyAndNumbersAll(inputText)
    local srcName = getLanguageEnglishName(srcLang)
    instruction = "You are a voice dictation post-processor. The input is " .. srcName ..
      ". Transliterate it into English (Latin) letters without translating its meaning. Keep already-English words, names, numbers and symbols. Correct likely speech-recognition errors using context, grammar and punctuation. Do not add or remove information. Output ONLY the final text."
  else
    inputText = applyDictionaryWords(spokenText, srcLang, "normal")
    local srcName = getLanguageEnglishName(srcLang)
    instruction = "You are a voice dictation post-processor. The input language is " .. srcName ..
      ". Correct grammar, spelling and speech-recognition errors using context. Add natural punctuation and capitalization. Keep the same language and script; do not translate. Do not add or remove information. Output ONLY the final text."
  end

  local emojiOn = prefs.getBoolean("use_emoji", false)
  local level = tostring(prefs.getString("emoji_level", "Medium Emoji"))
  if level == "Low Emoji Typing" then level = "Low" end
  if level == "Medium Emoji" then level = "Medium" end
  if level == "High Emoji" then level = "High" end
  if emojiOn and level ~= "None" and level ~= "Punctuation Only" then
    if level == "Low" then
      instruction = instruction .. " EMOJI PLACEMENT MODE: LOW. Add at most one familiar, highly relevant emoji at the END of each sentence, after punctuation. Do not put emoji at the beginning or between words. Do not add emoji to every sentence if it does not fit. No decorative symbols or emoji sequences. Preserve meaning and keep output screen-reader-friendly."
    elseif level == "Medium" then
      instruction = instruction .. " EMOJI PLACEMENT MODE: MEDIUM. Add a moderate number of familiar, context-relevant emojis, usually one per meaningful phrase/clause, not per word. Use natural comma, semicolon, and sentence boundaries. Example: 'Hello friends 馃檹, how is everyone doing? 馃槉 I am doing well.' Do not add emojis after every word. Avoid decorative symbols and duplicates. Keep punctuation, grammar, and spacing readable by screen readers."
    elseif level == "High" then
      instruction = instruction .. " EMOJI PLACEMENT MODE: HIGH. Use more emojis than Medium but keep the text readable: usually two familiar, context-relevant emojis per meaningful sentence/clause, and up to three only for a long clause with distinct ideas. Place emojis at natural phrase boundaries; do not add one to every word. Avoid repeated emojis, decorative symbol strings, obscure emojis, flags, skin-tone modifiers, and ZWJ sequences. Keep normal grammar, punctuation, and screen-reader-friendly spacing."
    else
      instruction = instruction .. " Do not use emojis."
    end
  else
    instruction = instruction .. " Do not use emojis."
  end

  local bodyFor = function(m)
    return '{"model":' .. tostring(JSONObject.quote(m)) ..
      ',"messages":[{"role":"system","content":' .. tostring(JSONObject.quote(instruction)) ..
      '},{"role":"user","content":' .. tostring(JSONObject.quote(inputText)) ..
      '}],"temperature":0.2,"max_tokens":1024}'
  end

  local models, seen = {}, {}
  local function addModel(m)
    m = trimStr(m)
    if m ~= "" and not seen[m] then seen[m] = true; table.insert(models, m) end
  end
  addModel(model)
  for _, m in ipairs(FALLBACK_GROQ_MODELS) do addModel(m) end
  local cached = tostring(prefs.getString("groq_models_cache", ""))
  for m in cached:gmatch("[^,]+") do addModel(m) end

  local nowSec = os.time()
  _G.groqBadModels = _G.groqBadModels or {}
  local tries = {}
  for _, m in ipairs(models) do
    local failedAt = _G.groqBadModels[m]
    if not (failedAt and (nowSec - failedAt) < 600) then table.insert(tries, m) end
    if #tries >= 4 then break end
  end
  if #tries == 0 then
    _G.groqBadModels = {}
    for i, m in ipairs(models) do if i <= 4 then table.insert(tries, m) end end
  end

  local usedModel, lastErr = model, "Groq request failed."
  for _, m in ipairs(tries) do
    local code, resp = groqHttp("POST", "chat/completions", apiKey, bodyFor(m), 15000)
    if code == 200 then
      local resultText = ""
      pcall(function()
        local obj = JSONObject(resp)
        local choices = obj.optJSONArray("choices")
        if choices and choices.length() > 0 then
          local msg = choices.getJSONObject(0).optJSONObject("message")
          if msg then resultText = tostring(msg.optString("content", "")) end
        end
      end)
      resultText = trimStr(resultText)
      if resultText == "" then return nil, "Groq returned no text." end
      if convertMode then resultText = trimStr(applyDictionaryWords(resultText, srcLang, "convert")) end
      usedModel = m
      return resultText, nil, usedModel
    end
    lastErr = describeGroqError(code, resp, m)
    if code == 429 or code == 404 then _G.groqBadModels[m] = os.time() end
    if code == -1 or code == 401 or code == 403 then break end
  end
  return nil, lastErr
end

local function getActiveAIProvider()
  local p = trimStr(prefs.getString("ai_provider", "Gemini"))
  if p ~= "Groq" then p = "Gemini" end
  return p
end

local function activeAIKey()
  if getActiveAIProvider() == "Groq" then
    return trimStr(prefs.getString("groq_api_key", ""))
  end
  return trimStr(prefs.getString("gemini_api_key", ""))
end

local function processWithSelectedAI(spokenText, srcLang, tgtLang, doTranslate, doConvert)
  if getActiveAIProvider() == "Groq" then
    return groqProcess(spokenText, srcLang, tgtLang, doTranslate, doConvert)
  end
  return geminiProcess(spokenText, srcLang, tgtLang, doTranslate, doConvert)
end

local function warmUpSelectedAI()
  if not prefs.getBoolean("ai_typing_enabled", false) then return end
  local provider = getActiveAIProvider()
  local key = activeAIKey()
  if key == "" then return end
  local model
  if provider == "Groq" then
    model = trimStr(prefs.getString("groq_model", DEFAULT_GROQ_MODEL))
  else
    model = trimStr(prefs.getString("gemini_model", DEFAULT_GEMINI_MODEL))
  end
  Thread(Runnable{
    run = function()
      pcall(function()
        if provider == "Groq" then
          groqHttp("GET", "models/" .. model, key, nil, 5000)
        else
          geminiHttp("GET", "models/" .. model, key, nil, 5000)
        end
      end)
    end
  }).start()
end

----------------------------------------------------------------

-- 4A-1. AI-only Messages & Quotes request detector/generator
-- When enabled, Gemini decides whether speech asks for a creative message/quote/poem.
-- No hard-coded language or topic dictionary is used.
----------------------------------------------------------------
local function geminiGenerateMessageOrQuote(spokenText, srcLang, emojiEnabled, emojiLevel, messageLength)
  local apiKey = trimStr(prefs.getString("gemini_api_key", ""))
  local model = trimStr(prefs.getString("gemini_model", DEFAULT_GEMINI_MODEL))
  if apiKey == "" then return nil, "API key is not set.", false end
  if model == "" then model = DEFAULT_GEMINI_MODEL end

  local languageName = getLanguageEnglishName(srcLang)
  local emojiInstruction = "Do not include emojis."
  if emojiEnabled then
    if emojiLevel == "Punctuation Only" then
      emojiInstruction = "Do not include emojis; use punctuation only."
    elseif emojiLevel == "Low Emoji Typing" or emojiLevel == "Low" then
      emojiInstruction = "Use only a few highly relevant emojis, sparingly."
    elseif emojiLevel == "High Emoji" or emojiLevel == "High" then
      emojiInstruction = "Use slightly more emojis than Medium: about two relevant emojis per meaningful clause, one near the start and one at the end. Never add an emoji after every word."
    else
      emojiInstruction = "Use one relevant emoji per meaningful phrase/clause, not per word; split at commas, semicolons and sentence endings. Keep the amount moderate and avoid clutter."
    end
  end

  local lengthInstruction = "Write a medium-length message."
  if messageLength == "Short Message" then
    lengthInstruction = "Write a short, ready-to-send message."
  elseif messageLength == "Long Message" then
    lengthInstruction = "Write a long, detailed, ready-to-send message, with no description or explanation."
  end

  local instruction = "You are an intent detector and creative-writing assistant for voice dictation. " ..
    "The speech recognition language is " .. languageName .. ". Read the user's utterance. " ..
    "If the user is explicitly asking you to CREATE/WRITE/GENERATE a message, wishes, quote, poem, caption, greeting, attitude message, sad message, birthday wish, or similar ready-to-send creative text, set generate=true and write the requested content. " ..
    "If the user is merely dictating text or mentioning these topics without asking you to create content, set generate=false and text to an empty string. " ..
    "When generate=true, write naturally and fluently in " .. languageName .. " and its proper script, unless the user explicitly requests another language. " ..
    "Make the response useful, with correct grammar, spelling, capitalization, and natural punctuation. Follow requested tone and topic. " .. lengthInstruction .. " Output ONLY the message, poem, quote, or greeting itself. Do NOT include a title unless requested, no description, no introduction, no explanation, no labels, and no commentary in any language. Output only the requested final content. " .. emojiInstruction .. " " ..
    "Return ONLY valid JSON with exactly these keys: {\"generate\":true/false,\"text\":\"...\"}. Escape JSON string characters correctly. No Markdown fences or extra keys."

  local body = '{"systemInstruction":{"parts":[{"text":' .. tostring(JSONObject.quote(instruction)) .. '}]},' ..
    '"contents":[{"role":"user","parts":[{"text":' .. tostring(JSONObject.quote(tostring(spokenText or ""))) .. '}]}],' ..
    '"generationConfig":{"temperature":0.35,"responseMimeType":"application/json"}}'

  local code, resp = geminiHttp("POST", "models/" .. model .. ":generateContent", apiKey, body, 20000)
  if code ~= 200 then return nil, describeGeminiError(code, resp, model), false end

  local raw = ""
  pcall(function()
    local root = JSONObject(resp)
    local candidates = root.optJSONArray("candidates")
    if candidates and candidates.length() > 0 then
      local content = candidates.getJSONObject(0).optJSONObject("content")
      local parts = content and content.optJSONArray("parts")
      if parts then
        for i = 0, parts.length() - 1 do raw = raw .. tostring(parts.getJSONObject(i).optString("text", "")) end
      end
    end
  end)
  raw = trimStr(raw):gsub("^```json", ""):gsub("^```", ""):gsub("```$", "")
  local ok, parsed = pcall(function() return JSONObject(raw) end)
  if not ok or not parsed then return nil, "Could not read message/quote response.", false end
  local shouldGenerate = parsed.optBoolean("generate", false)
  local output = trimStr(parsed.optString("text", ""))
  if shouldGenerate and output ~= "" then return output, nil, true end
  return nil, nil, false
end

----------------------------------------------------------------
----------------------------------------------------------------
local function openApiSettingsDialog()
  mainHandler.post(Runnable{
    run = function()
      local savedProvider = getActiveAIProvider()
      local savedKey = activeAIKey()
      local savedModel = savedProvider == "Groq"
        and trimStr(prefs.getString("groq_model", DEFAULT_GROQ_MODEL))
        or trimStr(prefs.getString("gemini_model", DEFAULT_GEMINI_MODEL))
      if savedModel == "" then savedModel = savedProvider == "Groq" and DEFAULT_GROQ_MODEL or DEFAULT_GEMINI_MODEL end

      local layout = LinearLayout(service)
      layout.setOrientation(LinearLayout.VERTICAL)
      layout.setPadding(40, 30, 40, 30)

      local providerLabel = TextView(service)
      providerLabel.setText("AI Provider:")
      providerLabel.setTextSize(16)
      layout.addView(providerLabel)

      local providerItems = ArrayList()
      providerItems.add("Gemini")
      providerItems.add("Groq")
      local providerSpinner = Spinner(service)
      local providerAdapter = ArrayAdapter(service, android.R.layout.simple_spinner_dropdown_item, providerItems)
      providerSpinner.setAdapter(providerAdapter)
      providerSpinner.setSelection(savedProvider == "Groq" and 1 or 0)
      layout.addView(providerSpinner)

      local keyLabel = TextView(service)
      keyLabel.setText(savedProvider .. " API Key:")
      keyLabel.setTextSize(16)
      layout.addView(keyLabel)

      local keyInput = EditText(service)
      keyInput.setHint("Paste " .. savedProvider .. " API key here")
      keyInput.setSingleLine(true)
      keyInput.setText(savedKey)
      layout.addView(keyInput)

      local btnGetKey = Button(service)
      btnGetKey.setText("Get " .. savedProvider .. " API Key")
      layout.addView(btnGetKey)

      local modelLabel = TextView(service)
      modelLabel.setText(savedProvider .. " Model:")
      modelLabel.setTextSize(16)
      layout.addView(modelLabel)

      local modelList = ArrayList()
      modelList.add(savedModel)
      local initialModels = savedProvider == "Groq" and FALLBACK_GROQ_MODELS or FALLBACK_GEMINI_MODELS
      for _, m in ipairs(initialModels) do if m ~= savedModel then modelList.add(m) end end
      local modelSpinner = Spinner(service)
      local modelAdapter = ArrayAdapter(service, android.R.layout.simple_spinner_dropdown_item, modelList)
      modelSpinner.setAdapter(modelAdapter)
      layout.addView(modelSpinner)

      local btnRefresh = Button(service)
      btnRefresh.setText("Refresh Models")
      layout.addView(btnRefresh)

      local btnTest = Button(service)
      btnTest.setText("Test API")
      layout.addView(btnTest)

      local statusView = TextView(service)
      statusView.setText("Status: Not tested yet.")
      statusView.setTextSize(15)
      statusView.setPadding(0, 10, 0, 10)
      layout.addView(statusView)

      local btnSave = Button(service)
      btnSave.setText("Save")
      layout.addView(btnSave)

      local btnBack = Button(service)
      btnBack.setText("Back")
      layout.addView(btnBack)

      local scroll = ScrollView(service)
      scroll.addView(layout)
      local dlg = AlertDialog.Builder(service)
        .setTitle("AI API Settings - Gemini / Groq")
        .setView(scroll)
        .create()

      local function providerNow()
        return trimStr(tostring(providerSpinner.getSelectedItem() or "Gemini")) == "Groq" and "Groq" or "Gemini"
      end

      local function getSelectedModel()
        local sel = modelSpinner.getSelectedItem()
        if sel then
          local s = trimStr(tostring(sel))
          if s ~= "" then return s end
        end
        return providerNow() == "Groq" and DEFAULT_GROQ_MODEL or DEFAULT_GEMINI_MODEL
      end

      local function fillModels(ids, preferred)
        modelList.clear()
        local selectedIndex = 0
        for i, id in ipairs(ids) do
          modelList.add(id)
          if id == preferred then selectedIndex = i - 1 end
        end
        modelAdapter.notifyDataSetChanged()
        modelSpinner.setSelection(selectedIndex)
      end

      local function refreshModels()
        local provider = providerNow()
        local key = trimStr(keyInput.getText())
        if key == "" then
          statusView.setText("Status: Enter the " .. provider .. " API key first.")
          service.asyncSpeak("Enter the " .. provider .. " API key first.")
          doVibrate("error")
          return
        end
        local preferred = getSelectedModel()
        statusView.setText("Status: Loading " .. provider .. " models...")
        service.asyncSpeak("Loading " .. provider .. " models")
        Thread(Runnable{
          run = function()
            local ids, err
            if provider == "Groq" then ids, err = fetchGroqModels(key) else ids, err = fetchGeminiModels(key) end
            mainHandler.post(Runnable{
              run = function()
                if ids and #ids > 0 then
                  fillModels(ids, preferred)
                  pcall(function()
                    local ed = prefs.edit()
                    if provider == "Groq" then ed.putString("groq_models_cache", table.concat(ids, ","))
                    else ed.putString("gemini_models_cache", table.concat(ids, ",")) end
                    ed.apply()
                  end)
                  local msg = tostring(#ids) .. " " .. provider .. " models loaded."
                  statusView.setText("Status: " .. msg)
                  service.asyncSpeak(msg)
                else
                  local msg = tostring(err or "Could not load models.")
                  statusView.setText("Status: " .. msg)
                  service.asyncSpeak(msg)
                  doVibrate("error")
                end
              end
            })
          end
        }).start()
      end

      providerSpinner.setOnItemSelectedListener(AdapterView.OnItemSelectedListener{
        onItemSelected = function(parent, view, position, id)
          local provider = providerNow()
          local key = provider == "Groq"
            and trimStr(prefs.getString("groq_api_key", ""))
            or trimStr(prefs.getString("gemini_api_key", ""))
          local model = provider == "Groq"
            and trimStr(prefs.getString("groq_model", DEFAULT_GROQ_MODEL))
            or trimStr(prefs.getString("gemini_model", DEFAULT_GEMINI_MODEL))
          if model == "" then model = provider == "Groq" and DEFAULT_GROQ_MODEL or DEFAULT_GEMINI_MODEL end
          keyLabel.setText(provider .. " API Key:")
          keyInput.setHint("Paste " .. provider .. " API key here")
          keyInput.setText(key)
          btnGetKey.setText("Get " .. provider .. " API Key")
          modelLabel.setText(provider .. " Model:")
          modelList.clear()
          modelList.add(model)
          local choices = provider == "Groq" and FALLBACK_GROQ_MODELS or FALLBACK_GEMINI_MODELS
          for _, m in ipairs(choices) do if m ~= model then modelList.add(m) end end
          modelAdapter.notifyDataSetChanged()
          modelSpinner.setSelection(0)
          statusView.setText("Status: " .. provider .. " selected.")
        end,
        onNothingSelected = function(parent) end
      })

      btnRefresh.setOnClickListener{ onClick = function(v) refreshModels() end }

      btnTest.setOnClickListener{
        onClick = function(v)
          local provider = providerNow()
          local key, model = trimStr(keyInput.getText()), getSelectedModel()
          if key == "" then
            statusView.setText("Status: Enter the " .. provider .. " API key first.")
            service.asyncSpeak("Enter the " .. provider .. " API key first.")
            doVibrate("error")
            return
          end
          statusView.setText("Status: Testing " .. provider .. " API...")
          service.asyncSpeak("Testing " .. provider .. " API")
          Thread(Runnable{
            run = function()
              local ok, msg
              if provider == "Groq" then ok, msg = testGroqKey(key, model) else ok, msg = testGeminiKey(key, model) end
              mainHandler.post(Runnable{
                run = function()
                  statusView.setText("Status: " .. (ok and "SUCCESS. " or "FAILED. ") .. msg)
                  doVibrate(ok and "success" or "error")
                  service.asyncSpeak((ok and "Success. " or "Failed. ") .. msg)
                end
              })
            end
          }).start()
        end
      }

      btnSave.setOnClickListener{
        onClick = function(v)
          local provider, key, model = providerNow(), trimStr(keyInput.getText()), getSelectedModel()
          local editor = prefs.edit()
          editor.putString("ai_provider", provider)
          if provider == "Groq" then
            editor.putString("groq_api_key", key)
            editor.putString("groq_model", model)
          else
            editor.putString("gemini_api_key", key)
            editor.putString("gemini_model", model)
          end
          editor.apply()
          statusView.setText("Status: Saved. Provider: " .. provider .. ". Model: " .. model)
          doVibrate("success")
          service.asyncSpeak(provider .. " API settings saved. Model " .. model)
        end
      }

      btnGetKey.setOnClickListener{
        onClick = function(v)
          local provider = providerNow()
          dlg.dismiss()
          pcall(function()
            local url = provider == "Groq" and "https://console.groq.com/keys" or "https://aistudio.google.com/apikey"
            local keyIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            keyIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            service.startActivity(keyIntent)
          end)
          service.asyncSpeak("Opening " .. provider .. " API key page")
        end
      }

      btnBack.setOnClickListener{ onClick = function(v) dlg.dismiss() end }
      prepareServiceDialog(dlg)
      dlg.show()
      if savedKey ~= "" then refreshModels() end
    end
  })
end

----------------------------------------------------------------
----------------------------------------------------------------
local function openTutorialDialog()
  -- Structure: { "Topic title", { {"Lesson title", [[Lesson text]]}, ... } }
  local topics = {

    {"1. Getting Started", {
      {"1.1 What this tool does", [[
RDS Voice Dictation lets you type by speaking, in almost any language, into any text box on your phone.

What it can do:
- Listen to your voice and type the words for you.
- Fix grammar, spelling and punctuation using Google Gemini AI (optional).
- Translate what you say into another language (optional).
- Write what you say in English letters, for example Tamil words typed in English letters (optional).
- Replace words you often get wrong using your own Dictionary (optional).
- Give vibration and spoken feedback so you always know what is happening.

Everything is controlled from the Settings screen. The next lessons explain each part step by step. Use the Next and Previous buttons below to move between lessons.
]]},
      {"1.2 Typing by voice, step by step", [[
Follow these steps every time you want to dictate:

1. Open any app with a text box (messages, notes, WhatsApp, email, etc.).
2. Tap inside the text box so the cursor is there.
3. Run this script.
4. You will feel one short vibration. This means the microphone is now listening.
5. Speak normally. You can speak for as long as you like, with as many words as you like. Short pauses will not stop the microphone.
6. Stop speaking. As soon as you finish, your speech is processed and typed into the text box.
7. The typed text is then read aloud so you can confirm it.

If the microphone does not start, make sure the cursor is really inside a text box. If there is no text box, the script opens the Settings screen instead.
]]},
      {"1.3 Opening the Settings screen", [[
To open Settings, run the script when the cursor is NOT inside a text box (for example on the home screen or in a menu).

The Settings screen has these items from top to bottom:
- Type with AI, and API Settings
- Voice Dictation Language
- Direct Translation, and the Target Language button
- Text Convert to English
- Use Dictionary, Dictionary Mode, and Manage Dictionary Words
- Vibration Feedback
- Auto Punctuation (Normal typing)
- Use Emoji, and Emoji Amount

At the bottom there are four buttons: Save and Exit, Cancel, Telegram Group, and Tutorial (this help, to the right of Telegram Group).
]]},
      {"1.4 Saving your settings", [[
Most changes on the Settings screen are saved ONLY when you press Save and Exit.

This includes: Type with AI, Voice Dictation Language, Target Language, Direct Translation, Text Convert to English, Use Dictionary, Vibration Feedback, Auto Punctuation, Use Emoji and Emoji Amount.

Important: if you switch Type with AI to ON but press Cancel (or close the screen another way), it stays OFF and your voice will be typed with normal typing.

Some things are saved immediately: pinning a language, adding or deleting dictionary words, and the Save button inside API Settings (which saves only the API key and model).
]]},
      {"1.5 Quick language swap", [[
If you run the script again while the microphone is still listening:

1. The microphone stops.
2. Your Voice Dictation Language and Target Language swap places. For example, Tamil and English exchange positions.
3. You hear "Switched to ..." followed by the new spoken language.
4. This change is saved immediately. You do not need to press Save and Exit.

This is very handy if you often switch between two languages. Run the script once more to start listening in the new language.
]]},
    }},

    {"2. Type with AI", {
      {"2.1 What Type with AI does", [[
Type with AI: ON / OFF

When ON, what you say is sent to Google Gemini AI before it is typed. The AI:
- Corrects grammar and spelling mistakes.
- Adds commas, full stops and question marks automatically.
- Fixes words that the microphone heard wrongly, using the meaning of the sentence.
- Starts sentences with proper capital letters.
- Keeps the same language and script as you spoke (it does not translate unless Direct Translation is ON).

When OFF, the script uses normal typing: your words are typed as heard, with only simple clean-up and your Dictionary words.
]]},
      {"2.2 What you need", [[
To use Type with AI you need:

1. An internet connection.
2. A Gemini API Key. It is free to create. See topic 3 (API Key Guide), which shows how to create it step by step.
3. Type with AI switched ON and saved with Save and Exit.

If you switch it ON while no API key is saved, you will hear "ON. Please set the selected AI provider API key in AI Settings." Open API Settings, add the key, then press Save there.
]]},
      {"2.3 AI with translation or English letters", [[
Type with AI works together with two other features:

- Direct Translation ON: Gemini translates your speech into the Target Language and adds proper grammar and punctuation.
- Text Convert to English ON (and Direct Translation OFF): Gemini writes your words in English letters, exactly as pronounced, with punctuation. It does not translate the meaning.
- Both OFF: Gemini only corrects grammar, spelling and punctuation in the same language.

Your Dictionary words are also applied: the Normal Typing dictionary for plain AI typing, and the English Converter dictionary for English-letter typing.
]]},
      {"2.4 When the AI fails", [[
Sometimes the AI cannot answer: the key is wrong or expired, the free quota is finished, the internet is down, or Google's server is busy.

In that case the script:
1. Gives a long vibration.
2. Says "AI failed" together with the reason.
3. Types your text using normal typing so you do not lose anything.

The script also tries other Gemini models automatically before giving up. See lesson 3.11.
]]},
      {"2.5 Making the AI faster", [[
Tips for faster AI typing:

- In API Settings choose gemini-2.5-flash-lite (fastest) or gemini-2.5-flash. Pro models are slower.
- Use a good Wi-Fi or mobile data connection.
- This version already turns off the extra thinking time of Flash models, keeps the connection open between requests, and prepares the connection while you are still speaking.
- Speak in complete phrases. Very long speech takes longer for the AI to process than short speech.
]]},
      {"2.6 Quick switch: AI mode and Normal mode", [[
Navigation shortcuts (run this script while screen-reader focus is on the navigation button):
- Home: toggle AI Mode and Normal Mode.
- Back: cycle Typing Mode 鈫� Translation Mode 鈫� English Converter. When AI Mode is ON, Message and Quotes and Query Mode are included before returning to Typing Mode.
- Overview / Recents: cycle Punctuation Only 鈫� Low Emoji Typing 鈫� Medium Emoji 鈫� High Emoji 鈫� repeat.

The selected mode is saved immediately, with spoken and vibration feedback. AI-only modes are cleared when AI Mode is switched OFF. If the focus is in a text box, normal voice typing continues as usual.
]]},
    }},

    {"3. API Key Guide & API Settings", {
      {"3.1 Before you start", [[
To use Type with AI you need a free Gemini API key from Google. This lesson group shows exactly how to create it and set it up, step by step.

What you need:
- A Google account (the same Gmail account you use on your phone is fine).
- An internet connection.
- A web browser on your phone (Chrome or any other browser).
- About 5 minutes.

Good to know:
- The Gemini API has a free tier. You normally do not need a credit card or any billing setup to start.
- The key is like a password that lets this script talk to Google's Gemini AI. Keep it private (see lesson 3.12).
- Google changes its website from time to time, so button names or positions may look slightly different. Look for the button named "Create API key".

Press Next to start with Step 1.
]]},
      {"3.2 Step 1: Open Google AI Studio", [[
Google AI Studio is the website where you create the key. There are two ways to open it.

Way A (easiest, from this script):
1. On the Settings screen press API Settings.
2. Press the Get API Key button.
3. Your browser opens the Google AI Studio API key page automatically.

Way B (manual):
1. Open your phone browser.
2. Type this address and open it: aistudio.google.com/apikey
   (If that page does not open, open aistudio.google.com and look for "Get API key" in the menu.)

Wait until the page finishes loading before you continue.
]]},
      {"3.3 Step 2: Sign in and accept the terms", [[
1. If Google asks you to sign in, choose your Google account and enter your password if required.
2. If this is your first time in Google AI Studio, a message about Terms of Service may appear. Read it and accept to continue.
3. If you are asked for your country or age confirmation, answer honestly. Some features are not offered in every country or to every account type.

Tip: if you have several Google accounts on your phone, make sure you pick the one you want to own the key. School or work accounts may be blocked by their administrators. A normal personal Gmail account works best.

When you see a page titled API keys (or a page with a button labelled Create API key), continue to Step 3.
]]},
      {"3.4 Step 3: Create the API key", [[
1. On the API keys page, tap the Create API key button.
2. Google may ask where to create the key. You will usually see two choices:
   - Create API key in new project: Google makes a new project for you automatically. Choose this if you are a beginner. It is the simplest option.
   - Create API key in existing project: choose this only if you already have a Google Cloud project and want to use it.
3. Tap the final Create API key button (or Create key) to confirm.
4. Wait a few seconds. Your new key appears in the list of keys on the page.

In some versions of the page you can type a name for the key first, for example "RDS Voice". A name is optional and only helps you recognise the key later.
]]},
      {"3.5 Step 4: Copy the key", [[
Your key is a long line of letters and numbers. It normally starts with AIza and has no spaces.

To copy it:
1. Find your new key in the list on the page.
2. Tap the copy icon next to the key. (If you do not see a copy icon, tap the key name or the key itself to open its details, then tap the copy icon there.)
3. Wait for a short message such as "Copied". If there is no icon, long press the key text, choose Select all, and then tap Copy.

Make sure you copy the whole key, without extra spaces at the start or end. A key with missing characters or spaces will give an "Invalid API key" error.

Google lets you open the key page again later and copy the key again, so you do not have to save it anywhere else right now.
]]},
      {"3.6 Step 5: Paste the key into this script", [[
1. Come back to the script's Settings screen. If it was closed, run the script again at a place where the cursor is NOT in a text box. Settings will open.
2. Press API Settings.
3. Tap the box under "Gemini API Key".
4. Long press inside the box and choose Paste. Your key appears in the box.
5. Check that there are no spaces before or after the key.

Do not press Save yet. First choose a model and test the key, as shown in the next lessons.
]]},
      {"3.7 Step 6: Choose a model", [[
Still in API Settings, find "Gemini Model" and open the list.

- gemini-2.5-flash-lite: the fastest. Recommended for voice typing.
- gemini-2.5-flash: fast and a little more accurate.
- gemini-2.5-pro: slowest. Not recommended for dictation.

If your list looks short, press Refresh Models (next lesson) to load every model your key can use.

You can change the model later at any time. If a model stops working, the script automatically tries other models (see lesson 3.11).
]]},
      {"3.8 Refresh Models", [[
Refresh Models asks Google which Gemini models your key can use and fills the model list with them.

- It runs automatically when you open API Settings and a key is already saved.
- Press it after pasting a new key to see all available models.
- It shows a status message such as "25 Gemini models loaded."
- Fast Flash models are sorted to the top of the list.
- The list is remembered and used as backup models if your chosen model fails.

If it says "Enter the API key first", paste your key into the key box.
]]},
      {"3.9 Test API", [[
Press Test API to check that everything works before you save. The Status line and a spoken message tell you the result.

SUCCESS means the key is valid, not expired, the model is available and quota is available right now.

Common failures:
- Invalid API key: the key was pasted wrongly or is incomplete. Copy it again.
- API key expired: create a new key (repeat lessons 3.2 to 3.5).
- Key reported as leaked: Google blocked it. Create a new key and keep it private.
- Quota exceeded or too many requests: wait a while, or pick another model.
- Model not found: choose another model from the list.
- Network error: check your internet connection.
]]},
      {"3.10 Save and Back", [[
- Save: stores the API key and the selected model on your phone. You will see "Status: Saved" and hear "API settings saved".
- Back: closes API Settings. It does not save anything by itself, so press Save first.

Last step: on the main Settings screen, switch Type with AI to ON and press Save and Exit. Without this the AI is not used.

Now try it: tap inside a text box, run the script and speak. After you stop, the AI-corrected text is typed.
]]},
      {"3.11 Automatic model switching", [[
If the chosen model cannot answer, the script switches to the next one automatically so your typing is not blocked.

- It tries your chosen model first, then models from your refreshed list, then common Flash models.
- A model that is out of quota or not found is skipped for 10 minutes.
- Temporary Google server errors are retried a few times.
- It stops early only if the key is invalid or there is no internet, because other models would fail too.
- At most 4 models are tried, to keep the waiting time short.
]]},
      {"3.12 Keeping your key safe", [[
- Do not share your key in chats, screenshots or public posts. Anyone who has it can use your free quota.
- The key is stored only on your phone, inside this script's settings.
- If you think someone has seen your key, open Google AI Studio, delete that key, create a new one and paste the new key here.
- You can create more than one key. To stop using an old key, delete it on the AI Studio API keys page.
- If you change your phone, you will need to enter the key again, but you can copy it from the AI Studio page.
]]},
      {"3.13 Problems while creating or using a key", [[
I cannot find Create API key:
- Open aistudio.google.com/apikey and make sure you are signed in. Look for a button named Create API key or a key icon in the menu.

The page asks me to accept terms or confirm something:
- Accept the terms with your personal Google account, then reload the page.

I get an error or the page does not open:
- Try another browser, check your internet, or try again later. Some work or school accounts are blocked, so use a personal Gmail account.

Test API says Invalid API key:
- Copy the key again, paste it without spaces, and press Test API.

Test API says Quota exceeded:
- Wait for some time, or choose gemini-2.5-flash-lite or another model.

Everything is correct but nothing is typed by AI:
- Make sure Type with AI is ON and that you pressed Save and Exit.
]]},
    }},

    {"4. Voice Dictation Language", {
      {"4.1 Choosing the language you speak", [[
Voice Dictation Language is the language you will speak.

1. On the Settings screen press the Voice Dictation Language button (it shows the current language).
2. A list of languages opens.
3. Tap a language once to select it.
4. Press Save and Exit to keep the change.

Languages are shown as Name (Country) [code], for example Tamil (India) [ta-IN]. Choose the version that matches how you speak, for example English (India) or English (United States).
]]},
      {"4.2 Searching the list", [[
The list contains many languages. To find one quickly, type part of its name in the search box at the top of the list, for example "tam" for Tamil.

The list updates as you type. Clear the box to see all languages again.
]]},
      {"4.3 Pin to Top", [[
If you use a few languages often, you can pin them so they appear at the top of the list with a pin icon.

1. Open the language list.
2. Long press the language.
3. Choose Pin to Top.

To remove it, long press the pinned language and choose Unpin from Top. Pinning is saved immediately.
]]},
      {"4.4 Add to Dictionary", [[
Long press a language and choose Add to Dictionary to add that language to your Dictionary list.

You must do this before you can add your own word replacements for that language. See topic 7 (Dictionary) for how to add words afterwards.

You will hear "<language> added to Dictionary" when it succeeds.
]]},
    }},

    {"5. Direct Translation", {
      {"5.1 What Direct Translation does", [[
Direct Translation: ON / OFF

When ON, the words you speak are translated into another language and that translation is typed.

Example: speak in Tamil, and English text is typed.

When OFF, your words are typed in the same language you spoke.
]]},
      {"5.2 Choosing the target language", [[
The Target Language button sits below the Direct Translation button.

- It is disabled (greyed out) until Direct Translation is ON.
- Press it to open the language list, search, and tap the language you want to translate into.
- Press Save and Exit to keep your choice.

The Quick language swap (lesson 1.5) also exchanges the spoken language and the target language.
]]},
      {"5.3 With AI and without AI", [[
Type with AI ON: Gemini translates and also adds proper grammar, capitalization and punctuation. This usually gives the best result.

Type with AI OFF (or AI failed): Google Translate translates the text. If the target language is English, the result is also checked for grammar using LanguageTool.

Priority note: Direct Translation has priority over Text Convert to English. If Direct Translation is ON, Text Convert to English is not used.
]]},
    }},

    {"6. Text Convert to English", {
      {"6.1 What it does", [[
Text Convert to English: ON / OFF

This is NOT translation. It writes the words you spoke using English letters, exactly as they sound.

Example: you speak a Tamil greeting, and it is typed in English letters, such as "Vanakkam nanbargale". The meaning stays the same and only the letters change.

This is useful when your keyboard or chat is in English but you speak another language.
]]},
      {"6.2 With AI and without AI", [[
Type with AI ON: Gemini writes the English-letter version with natural simple spelling, punctuation and capital letters. Words that are already English, names, numbers and file extensions stay as normal English.

Type with AI OFF: Google's English-letter (romanization) service is used. Special accent marks are cleaned so only plain English letters remain.

In both cases your English Converter dictionary words are applied.
]]},
      {"6.3 Built-in word conversions", [[
Common words are converted automatically to their usual English form when your spoken language is not English. Examples:

- God names and words such as God, Bhagwan, Ishwar.
- Festivals such as Diwali, Deepavali, Pongal, Onam, Ugadi, Ganesh Chaturthi, Christmas, Ramzan.
- File types such as .pdf, .mp3, .mp4, .zip, .rar, .apk, .jpg, .png, .txt.
- Tech words such as coding, programming, Android, Lua, Python.
- Titles such as Sir, Madam, Mr., Uncle, Aunty, brother, sister.
- Greetings such as Good morning, Good night, hello, hi, thanks, please, welcome, bro, sis.
- Rupee words next to numbers become Rs., for example "Rs. 500".
]]},
      {"6.4 When it is not used", [[
Text Convert to English does nothing when:
- Direct Translation is ON (translation has priority).
- Your Voice Dictation Language is English (there is nothing to convert).
- The switch is OFF.

If everything is OFF, your speech is typed as heard, with Dictionary words applied.
]]},
    }},

    {"7. Dictionary", {
      {"7.1 Use Dictionary switch", [[
Use Dictionary: ON / OFF

A Dictionary is your own list of "wrong word -> correct word" pairs. When the switch is ON, the script replaces wrong words automatically before the text is typed.

Use it for names, places and special words that the microphone often hears wrongly.

When OFF, no replacements are made, but your saved words are kept.
]]},
      {"7.2 The two dictionary modes", [[
Dictionary Mode has two choices:

- Normal Typing: used for normal typing and for AI typing that only fixes grammar.
- English Converter: used when Text Convert to English is ON.

Each mode keeps its own list of words, so you can set different corrections for each.

Replacements match whole words only, and they apply only when your Voice Dictation Language is the same language you added to the Dictionary.
]]},
      {"7.3 Step 1: add a language", [[
Before adding words you must add the language to the Dictionary:

1. Press the Voice Dictation Language button.
2. Long press the language (for example Tamil (India)).
3. Choose Add to Dictionary.

If you press Manage Dictionary Words before doing this, you hear "No languages in dictionary" and instructions for adding one.
]]},
      {"7.4 Step 2: add words", [[
1. Choose Normal Typing or English Converter in Dictionary Mode.
2. Press Manage Dictionary Words.
3. Tap your language in the list.
4. In Wrong word, type the word as it is currently typed incorrectly.
5. In Correct word, type what it should be.
6. Press Save Word. You will hear "Saved <wrong> to <correct>".

Your saved words appear in the list below as "wrong -> correct". Add as many as you like.
]]},
      {"7.5 Deleting words and languages", [[
Delete a word: in the word list, long press the word. It is deleted at once and you hear "Deleted <word>".

Remove a whole language: in the language list (the screen that appears after pressing Manage Dictionary Words), long press the language. It is removed from the Dictionary together with all its words.

Deleting cannot be undone, so be careful.
]]},
    }},

    {"8. Vibration Feedback", {
      {"8.1 What the vibrations mean", [[
Vibration Feedback: ON / OFF

- One short vibration: the microphone has started listening.
- A double vibration: your speech was recognized successfully.
- One long vibration: something went wrong (recognition error or AI failure).
- A vibration also confirms actions such as pinning a language or saving a dictionary word.
]]},
      {"8.2 Turning it off", [[
If you do not want vibrations, set Vibration Feedback to OFF and press Save and Exit.

You will still hear the spoken messages, so you know what is happening even without vibration.
]]},
    }},

    {"9. Use Emoji", {
      {"9.1 What Use Emoji does", [[
Use Emoji: ON / OFF

When ON, emojis that match the meaning or feeling of what you said are added to your typed text. It works in both modes:

- AI mode (Type with AI ON): the Gemini AI chooses emojis that fit the emotion and mood of your sentence. If the AI adds none, the word list below adds some, so emojis appear in every mode.
- Normal mode (Type with AI OFF, or when the AI fails): the script adds emojis in two ways:
  1. After words found in a built-in word list, in English and Tamil. For example, a thank-you word gets a folded-hands emoji, and a birthday word gets a cake emoji.
  2. At the end of the sentence, an emoji that matches the overall mood of the sentence (happy, sad, angry, love, thanks, question, and so on).

When Use Emoji is OFF, no emojis are added in either mode.

The normal-mode emojis are standard emojis that every phone keyboard supports. The word list is shown in lessons 9.4 and 9.5, and the mood list in lesson 9.3.
]]},
      {"9.2 Emoji Amount", [[
Emoji Amount can be changed only when Use Emoji is ON.

AI mode:
- None: no emojis.
- Low: at most one emoji in the whole text, and only if it clearly matches.
- Medium: one suitable emoji per meaningful phrase/clause, separated by commas, semicolons or sentence endings; never one per word (default).
- High: several expressive emojis.

Normal mode:
- None: no emojis.
- Low: one emoji only, after the first matching word. No emoji at the end.
- Medium: one suitable emoji per meaningful phrase/clause; never add an emoji after every word (default).
- High: about two suitable emojis per meaningful clause, with an optional third for long clauses; never add an emoji after every word.

Each emoji is added only once in a sentence. If no mood is found in the sentence, no end emoji is added. Press Save and Exit to keep your choice.
]]},
      {"9.3 End-of-sentence mood emojis (normal mode)", [[
In normal mode the script looks at the words of the sentence and picks one emoji for its mood. If several moods are found, the one with the most matching words wins. A question gets a thinking-face emoji. If the same emoji is already in the sentence, it is not repeated.

Format: emoji, English words / Tamil words (examples)

馃槉 happy, glad, joy, joyful, smile, pleased  /  喈畷喈苦喁嵿畾喁嵿畾喈�, 喈氞喁嵿喁嬥喈瘝, 喈氞喁嵿喁嬥畾喈瘝, 喈ㄠ喁嵿喈�
馃槀 lol, haha, funny, laugh, laughing, joke  /  喈氞喈班, 喈氞喈班喈瘝喈瘉, 喈曕喈瘑喈熰, 喈ㄠ畷喁堗畾喁嵿畾喁佮喁�
馃槩 sad, cry, crying, tears, upset, hurt  /  喈氞瘚喈曕喁�, 喈呧喁佮畷喁�, 喈呧喁�, 喈曕喈侧瘓
馃槨 angry, anger, furious, mad, hate, annoyed  /  喈曕瘚喈喁�, 喈曕瘚喈掂喁�, 喈嗋喁嵿喈苦喈瘝, 喈庎喈苦畾喁嵿畾喈侧瘝
鉂わ笍 love, loved, loving, miss you, dear, sweet  /  喈曕喈む喁�, 喈呧喁嵿喁�, 喈喈氞喁�, 喈ㄠ瘒喈氞喁�
馃槷 wow, amazing, surprised, shocked, unbelievable, incredible  /  喈嗋畾喁嵿畾喈班喈喁�, 喈呧喈苦喁嵿畾喁嵿畾喈�, 喈掂喈掂瘝, 喈ㄠ喁嵿喈掂瘒
馃帀 congratulations, congrats, celebrate, celebration, party, won  /  喈掂喈脆瘝喈む瘝喈む瘉, 喈曕瘖喈｀瘝喈熰喈熰瘝喈熰喁�, 喈掂瘑喈编瘝喈编, 喈喈班瘝喈熰瘝喈熰
馃檹 thanks, thank you, thank, please, grateful, blessed  /  喈ㄠ喁嵿喈�, 喈む瘒喈權瘝喈曕瘝喈膏瘝, 喈瘝喈赤瘈喈膏瘝, 喈喁嵿喈苦畷喁嵿畷
馃憤 agree, agreed, sure, okay, ok, yes  /  喈嗋喈�, 喈嗋喁�, 喈氞喈苦喈距畷, 喈夃喁嵿喁�
鈿狅笍 urgent, important, emergency, warning, careful, hurry  /  喈呧喈氞喈瘝, 喈瘉喈曕瘝喈曕喈喁�, 喈庎畾喁嵿畾喈班喈曕瘝喈曕瘓, 喈溹喈曕瘝喈曕喈班喁�
馃槾 tired, sleepy, exhausted, bored, boring, sleep  /  喈曕喁堗喁嵿喁�, 喈む瘋喈曕瘝喈曕喁�, 喈氞瘚喈班瘝喈掂瘉, 喈む瘋喈權瘝喈�
馃 think, thinking, confused, wonder, maybe, perhaps  /  喈瘚喈氞, 喈曕瘉喈脆喁嵿喈瘝, 喈氞喁嵿喁囙畷喈瘝, 喈む瘑喈班喈
馃樂 sick, fever, headache, ill, unwell  /  喈曕喈瘝喈氞瘝喈氞喁�, 喈む喁堗喈侧, 喈夃疅喈瘝喈瘉 喈氞喈苦喈苦喁嵿, 喈夃疅喈瘝喈瘉 喈氞喈苦喈苦喁嵿喁�
馃憢 hello, hi, hey, bye, goodbye, good morning  /  喈灌喁�, 喈灌喈瘝, 喈曕瘉喈熰瘝 喈喈班瘝喈┼喈權瘝, 喈曕瘉喈熰瘝 喈ㄠ瘓喈熰瘝

Tip: when your speech recognition adds full stops, question marks or exclamation marks, each sentence is handled separately in High mode. Without punctuation, the whole text is treated as one sentence.
]]},
      {"9.4 Normal mode emoji list (part 1)", [[
Format: emoji, English words / Tamil words

馃槉 happy, glad, smile, smiling, joy, joyful, cheerful, santhosham, magizhchi  /  喈畷喈苦喁嵿畾喁嵿畾喈�, 喈氞喁嵿喁嬥喈瘝, 喈氞喁嵿喁嬥畾喈瘝, 喈畷喈苦喁�, 喈瘉喈┼瘝喈┼畷喁�
馃槀 lol, haha, funny, laugh, laughing, hilarious, joke, comedy  /  喈氞喈班喈瘝喈瘉, 喈氞喈班喈む瘝, 喈曕喈瘑喈熰, 喈ㄠ畷喁堗畾喁嵿畾喁佮喁�, 喈溹瘚喈曕瘝
馃槩 sad, cry, crying, tears, upset, heartbroken  /  喈氞瘚喈曕喁�, 喈呧喁佮畷喁�, 喈呧喁佮喁�, 喈曕喈侧瘓, 喈掂喁佮喁嵿喈瘝
馃槨 angry, anger, furious, mad  /  喈曕瘚喈喁�, 喈曕瘚喈掂喁�, 喈嗋喁嵿喈苦喈瘝
鉂わ笍 love, loved, loving, heart, dear, kadhal, anbu  /  喈曕喈む喁�, 喈呧喁嵿喁�, 喈囙喈喁�, 喈喈氞喁�, 喈ㄠ瘒喈氞喁�
馃槏 beautiful, gorgeous, lovely, cute, azhagu  /  喈呧喈曕瘉, 喈呧喈曕喈�, 喈呧喈曕喈�
馃憤 well done, excellent, great, awesome, perfect, super, nice, wonderful  /  喈氞瘋喈瘝喈喁�, 喈呧喁佮喁�, 喈氞喈编喁嵿喁�, 喈ㄠ喁嵿喁�, 喈ㄠ喁嵿喈む瘉, 喈呧喁嵿喁佮喈瘝
馃憣 ok, okay, agreed, sure, fine  /  喈撪畷喁�
馃檹 thanks, thank you, thank, please, namaste, namaskaram, nandri, vanakkam, sorry, blessings, pray, prayer  /  喈ㄠ喁嵿喈�, 喈掂喈曕瘝喈曕喁�, 喈喁嵿喈苦畷喁嵿畷, 喈喁嵿喈苦喁嵿喁�, 喈喈班喈班瘝喈む瘝喈む喁�, 喈掂瘒喈｀瘝喈熰瘉喈曕喈编瘒喈┼瘝, 喈瘝喈赤瘈喈膏瘝, 喈む瘒喈權瘝喈曕瘝喈膏瘝
馃寘 good morning, morning, sunrise  /  喈曕喈侧瘓 喈掂喈曕瘝喈曕喁�, 喈曕喈侧瘓, 喈掂喈熰喈喁�, 喈曕瘉喈熰瘝 喈喈班瘝喈┼喈權瘝
馃寵 good night, night, moon  /  喈囙喈苦 喈囙喈掂瘉, 喈曕瘉喈熰瘝 喈ㄠ瘓喈熰瘝, 喈囙喈掂瘉, 喈ㄠ喈侧, 喈ㄠ喈侧喁�
鈽€锔� sun, sunny, hot, summer, afternoon  /  喈掂瘑喈喈侧瘝, 喈氞瘋喈班喈喁�, 喈曕瘚喈熰瘓, 喈掂瘑喈瘝喈喁�
馃導锔� rain, raining, rainy, monsoon  /  喈喁�, 喈喁堗畷喁嵿畷喈距喈瘝
鉂勶笍 cold, winter, snow  /  喈曕瘉喈赤喈班瘝, 喈喈苦畷喁嵿畷喈距喈瘝
馃帀 congratulations, congrats, celebrate, celebration, party, winner, wishes, wish  /  喈掂喈脆瘝喈む瘝喈む瘉, 喈曕瘖喈｀瘝喈熰喈熰瘝喈熰喁�, 喈掂瘑喈编瘝喈编, 喈喈班瘝喈熰瘝喈熰
馃巶 birthday, cake  /  喈喈编喁嵿喈ㄠ喈赤瘝, 喈喈编喁嵿 喈ㄠ喈赤瘝, 喈曕瘒喈曕瘝
馃獢 diwali, deepavali  /  喈む瘈喈喈掂喈�, 喈む瘈喈喁�
馃巹 christmas, xmas  /  喈曕喈编喈膏瘝喈む瘉喈喁�, 喈曕喈编喈膏瘝喈喁�
馃尵 pongal, harvest  /  喈瘖喈權瘝喈曕喁�, 喈呧喁佮喈熰瘓
馃悩 ganesh, ganesha, vinayagar, vinayaka, ganapathi  /  喈掂喈ㄠ喈畷喈班瘝, 喈曕喁囙喁�, 喈曕喁囙畾喈班瘝, 喈喈赤瘝喈赤瘓喈喈班瘝, 喈曕喈喈�
馃晧锔� god, om, bhagwan  /  喈曕疅喈掂瘉喈赤瘝, 喈囙喁堗喈┼瘝, 喈嗋喁嵿疅喈掂喁�, 喈氞喈, 喈む瘑喈瘝喈掂喁�
馃洉 temple  /  喈曕瘚喈掂喈侧瘝, 喈曕瘚喈喈侧瘝
馃嵔锔� food, lunch, dinner, meal, eat, eating, hungry, breakfast  /  喈氞喈瘝喈喈熰瘉, 喈氞喈瘝喈喈�, 喈夃喈掂瘉, 喈喈苦 喈夃喈掂瘉, 喈囙喈掂瘉 喈夃喈掂瘉, 喈曕喈侧瘓 喈夃喈掂瘉, 喈畾喈�, 喈熰喈喁�
鈽� coffee, tea  /  喈曕喈, 喈む瘒喈ㄠ瘈喈班瘝
馃彔 home, house  /  喈掂瘈喈熰瘉, 喈掂瘈喈熰瘝喈熰喈侧瘝, 喈囙喁嵿喈瘝
馃殞 bus  /  喈瘒喈班瘉喈ㄠ瘝喈む瘉, 喈喁�
馃殕 train, railway  /  喈班喈苦喁�, 喈班瘑喈喈侧瘝, 喈囙喈喈侧瘝
鉁堬笍 flight, airport, plane  /  喈掂喈喈┼喁�, 喈掂喈喈� 喈ㄠ喈侧瘓喈喁�
馃殫 travel, trip, journey, driving  /  喈喈｀喁�, 喈氞瘉喈编瘝喈编瘉喈侧, 喈掂喁嵿疅喈�
馃摓 call, calling, telephone, phone call  /  喈む瘖喈侧瘓喈瘒喈氞, 喈呧喁堗喁囙畾喈�
馃摫 mobile, smartphone, whatsapp, android  /  喈瘖喈瘓喈侧瘝, 喈掂喈熰瘝喈膏瘝喈呧喁�, 喈嗋喁嵿疅喁嵿喈距喁嵿疅喁�, 喈氞瘑喈喈�
馃捇 computer, laptop, coding, programming, software  /  喈曕喈苦喈�, 喈曕喁嵿喁嵿喁傕疅喁嵿疅喈班瘝, 喈侧瘒喈瘝喈熰喈瘝, 喈曕瘚喈熰喈權瘝, 喈瘑喈┼瘝喈瘖喈班瘉喈赤瘝
馃挵 money, cash, salary, payment, rupees, rupee  /  喈喈瘝, 喈曕喈氞瘉, 喈氞喁嵿喈赤喁�, 喈班瘋喈喈瘝
馃摎 book, books, study, studying, exam, school, college, education  /  喈疅喈苦喁嵿喁�, 喈疅喈苦畷喁嵿畷, 喈瘉喈む瘝喈む畷喈瘝, 喈む瘒喈班瘝喈掂瘉, 喈喁嵿喈�, 喈曕喁嵿喁傕喈�, 喈曕喁嵿喈�
]]},
      {"9.5 Normal mode emoji list (part 2)", [[
Format: emoji, English words / Tamil words

馃捈 office, work, meeting, job, business  /  喈呧喁佮喈侧畷喈瘝, 喈掂瘒喈侧瘓, 喈瘈喈熰瘝喈熰喈權瘝, 喈む瘖喈脆喈侧瘝
馃彞 hospital, doctor, medicine, fever, sick, illness, health  /  喈喁佮喁嵿喁佮喈喁�, 喈喁佮喁嵿喁佮喈班瘝, 喈熰喈曕瘝喈熰喁�, 喈喁佮喁嵿喁�, 喈曕喈瘝喈氞瘝喈氞喁�, 喈ㄠ瘚喈瘝, 喈嗋喁嵿喈む瘝喈む喈班
馃挭 strong, gym, exercise, workout, strength  /  喈夃疅喈编瘝喈喈苦喁嵿畾喈�, 喈掂喈苦喁�
馃槾 sleep, sleepy, sleeping, tired, rest  /  喈む瘋喈曕瘝喈曕喁�, 喈む瘋喈權瘝喈�, 喈曕喁堗喁嵿喁�, 喈撪喁嵿喁�
馃尮 flower, flowers, rose  /  喈班瘚喈溹, 喈喈班瘝, 喈瘋喈曕瘝喈曕喁�
馃惗 dog, puppy  /  喈ㄠ喈瘝, 喈ㄠ喈瘝喈曕瘝喈曕瘉喈熰瘝喈熰
馃惐 cat, kitten  /  喈瘋喈┼瘓
馃悇 cow  /  喈喈熰瘉, 喈畾喁佮喈距疅喁�
馃キ mango  /  喈喈瘝喈喈瘝, 喈喈權瘝喈曕喈瘝
馃崒 banana  /  喈掂喈脆瘓喈瘝喈喈瘝
鈿� football, soccer  /  喈曕喈侧瘝喈喁嵿喁�
馃弿 cricket, ipl  /  喈曕喈班喈曕瘝喈曕瘑喈熰瘝
馃幀 movie, film, cinema, theatre  /  喈疅喈瘝, 喈む喈班瘓喈瘝喈疅喈瘝, 喈氞喈┼喈, 喈む喈瘒喈熰瘝喈熰喁�
馃幍 song, songs, music, singing  /  喈喈熰喁�, 喈喈熰瘝喈熰瘉, 喈囙畾喁�
馃巵 gift, present, surprise  /  喈喈苦畾喁�, 喈喈苦畾喁佮畷喈赤瘝
鈴� alarm, reminder, clock  /  喈呧喈距喈瘝, 喈ㄠ喈┼瘓喈掂瘋喈熰瘝喈熰喁�
鉁� completed, finished, done, success, successful  /  喈瘉喈熰喈ㄠ瘝喈む喁�, 喈瘉喈熰喈ㄠ瘝喈む瘉喈掂喈熰瘝喈熰喁�, 喈瘉喈熰喈む瘝喈む瘉喈掂喈熰瘝喈熰瘒喈┼瘝, 喈掂瘑喈编瘝喈编喈曕喈喈�
鉂� cancelled, canceled, rejected, wrong, failed, failure  /  喈班喁嵿喁�, 喈む喈编瘉, 喈む瘚喈侧瘝喈掂, 喈ㄠ喈班喈曕喈�
鈿狅笍 warning, careful, danger, alert, attention, urgent, important  /  喈庎畾喁嵿畾喈班喈曕瘝喈曕瘓, 喈溹喈曕瘝喈曕喈班喁�, 喈呧喈氞喈瘝, 喈瘉喈曕瘝喈曕喈喁�, 喈嗋喈む瘝喈む瘉
鉂� question, doubt  /  喈曕瘒喈赤瘝喈掂, 喈氞喁嵿喁囙畷喈瘝
馃 think, thinking, thought, confused, maybe, idea  /  喈瘚喈氞, 喈瘚喈氞喁�, 喈曕瘉喈脆喁嵿喈瘝, 喈氞喈ㄠ瘝喈む喁�
馃槷 wow, amazing, surprised, shocked, unbelievable  /  喈嗋畾喁嵿畾喈班喈喁�, 喈呧喈苦喁嵿畾喁嵿畾喈�, 喈掂喈掂瘝
馃槑 cool, stylish, style  /  喈膏瘝喈熰瘓喈侧瘝, 喈曕瘋喈侧瘝
馃 friend, friends, friendship, deal  /  喈ㄠ喁嵿喈班瘝, 喈ㄠ喁嵿喈┼瘝, 喈ㄠ喁嵿喈�, 喈ㄠ疅喁嵿喁�, 喈む瘚喈脆, 喈掄喁嵿喈ㄠ瘝喈む喁�
馃應 family, parents, mother, father, mom, dad, amma, appa  /  喈曕瘉喈熰瘉喈瘝喈喁�, 喈呧喁嵿喈�, 喈呧喁嵿喈�, 喈瘑喈编瘝喈编瘚喈班瘝
馃懚 baby, child, kid, kids, children  /  喈曕瘉喈脆喁嵿喁�, 喈曕瘉喈脆喁嵿喁堗畷喈赤瘝, 喈喈瘝喈
馃帗 graduation, degree, graduate, certificate  /  喈疅喁嵿疅喈瘝, 喈疅喁嵿疅喈む喈班, 喈氞喈┼瘝喈编喈む喁�
馃弳 trophy, champion, award  /  喈曕瘚喈瘝喈瘓, 喈氞喈瘝喈喈喁�, 喈掂喈班瘉喈む瘉
馃洅 shopping, market, store  /  喈粪喈瘝喈喈權瘝, 喈氞喁嵿喁�, 喈曕疅喁堗畷喁嵿畷喁�, 喈曕疅喁堗喈苦喁�
馃敟 fire, trending, blockbuster, superhit  /  喈ㄠ瘑喈班瘉喈瘝喈瘉
馃専 star, stars, shine, brilliant, best  /  喈ㄠ疅喁嵿畾喈む瘝喈む喈班喁�, 喈氞喈编喁嵿
馃 hug, welcome, welcomed  /  喈掂喈掂瘒喈编瘝喈曕喈编瘚喈瘝, 喈掂喈掂瘒喈编瘝喈瘉, 喈掂瘑喈侧瘝喈曕喁�, 喈呧喈掂喁堗喁嵿喁�
馃憢 hello, hi, hey, bye, goodbye, see you  /  喈灌喁�, 喈灌喈瘝, 喈瘓 喈瘓, 喈瘈喈｀瘝喈熰瘉喈瘝 喈氞喁嵿喈苦喁嵿喁嬥喁�
]]},
    }},

    {"10. Bottom Buttons", {
      {"10.1 Save and Exit", [[
Saves every change you made on the Settings screen and closes it. You will hear "Settings saved."

Always press this after changing languages or any ON/OFF button.
]]},
      {"10.2 Cancel", [[
Closes the Settings screen without saving the changes you just made.

Things that were already saved immediately (pinned languages, dictionary words, API key saved with Save in API Settings) stay saved.
]]},
      {"10.3 Telegram Group", [[
Opens our Telegram group in the Telegram app, where you can ask for help, report problems and get new versions of the script.
]]},
      {"10.4 Tutorial", [[
This help. It is the button at the right end of the bottom row on the Settings screen, next to Telegram Group.

How to use it:
- The first screen shows only the main topics: 1, 2, 3 and so on. Tap a topic to open it.
- You go straight to the first lesson of that topic. There is no extra list in between.
- Use Next and Previous at the bottom to move through the lessons. When a topic ends, Next continues with the next topic, and Previous goes back to the previous topic.
- On the topic list screen, Next and Previous also work. Next starts from the first lesson (or continues from the last lesson you read), and Previous goes backwards.
- Press Back to return to the topic list, and Close to leave the tutorial.
]]},
    }},

    {"11. How Your Speech Is Processed", {
      {"11.1 Order of processing", [[
After you stop speaking, the script picks one method in this order:

1. Type with AI ON and the key works: Gemini AI does the job (grammar and punctuation, plus translation or English letters if enabled).
2. Otherwise, if Direct Translation is ON: Google Translate, plus grammar correction for English.
3. Otherwise, if Text Convert to English is ON: English-letter conversion.
4. Otherwise: your spoken text with Dictionary words (normal typing).

So normal typing is used whenever Type with AI is OFF, and also as the safety net if the AI fails.
]]},
      {"11.2 What normal typing does", [[
Normal typing (without AI) cleans the text:
- Extra spaces are removed.
- Auto Punctuation (when ON) adds commas, and a question mark, exclamation mark or full stop at the end. See lesson 11.4.
- If Auto Punctuation is OFF, a trailing comma or full stop is removed instead.
- Emojis are added if Use Emoji is ON (see topic 9).
- The first letter is capitalized (for languages with capital letters).
- One space is added at the end, so you can keep dictating the next phrase.

AI typing keeps the punctuation the AI added and also ends with one space.
]]},
      {"11.3 Long speech and pauses", [[
You can speak for as long as you want. The microphone waits for a short silence before deciding you have finished.

If speech recognition ends with an error but some of your words were already recognized, the script types those recognized words instead of losing them.

You can tune the waiting time inside the script: SILENCE_END_MS (default 2000) and SILENCE_POSSIBLE_MS (default 1500). Higher numbers allow longer pauses, and lower numbers type sooner after you stop.
]]},
      {"11.4 Auto Punctuation in normal mode", [[
Auto Punctuation: ON / OFF (on the Settings screen, above Use Emoji)

It works in every mode: normal typing, Direct Translation, Text Convert to English, and also as a safety check on AI output (the AI already adds punctuation, so only missing marks are added). It looks at the words you spoke and adds punctuation, in the same way the emojis are added. See lesson 11.6 for how each mode works.

1. Ending mark (only if your speech does not already end with one):
- Question mark: when the sentence is a question. For example it starts with what, why, how, when, where, who or which; starts with is, are, do, can, will (and so on) followed by I, you, he, she, it, we or they; contains a Tamil question word such as enna, yen, eppadi, enge, yaar; or ends like a Tamil yes/no question (for example words ending in "-aa" forms such as varuveengala).
- Exclamation mark: for greetings, thanks and wishes. For example hello, thank you, congratulations, wow, happy birthday, and Tamil words for greetings, thanks and praise. Words like hello, hi and hey (and the Tamil greeting words) count only at the start of the sentence. Words like thanks, wow and congratulations also count anywhere in a short sentence (6 words or fewer).
- Full stop: for everything else.

2. Commas:
- After an opening word at the start of a sentence: for example however, therefore, finally, hello, hi, yes, okay, good morning, by the way, in fact, and Tamil words such as aanaal, aagave, enave, vanakkam, mundhalil.
- Before words such as but, although, whereas, otherwise and the Tamil word for "but" when they come in the middle of a sentence.

Examples (emojis off):
- "hello how are you" becomes "Hello, how are you?"
- "we can go now but it is raining" becomes "We can go now, but it is raining."
- "thank you so much" becomes "Thank you so much!"
- A Tamil "how are you" question gets a question mark at the end.

Other languages: Hindi, Marathi, Nepali, Sanskrit and Bengali use the danda mark for full stops. Chinese and Japanese use their full-width marks. Arabic, Persian and Urdu use their own question mark.
]]},
      {"11.5 Auto Punctuation limits and tips", [[
Auto Punctuation uses word rules, not artificial intelligence, so it is a good helper but not perfect.

- It adds an ending mark only at the end of your whole text. If your speech has several sentences without any pauses marked, it is treated as one sentence. Speech that already contains full stops, question marks or exclamation marks is kept as it is, and each part is checked for commas.
- A few words can fool it. For example a sentence that merely mentions a question word may get a question mark. You can fix the result by hand.
- For the best punctuation, turn on Type with AI. The AI understands the full meaning of each sentence.
- If you do not want any punctuation to be added, turn Auto Punctuation OFF. Then a trailing comma or full stop is removed, as before.
- Advanced: the word lists are in section 7B of the script. You can add or remove words there.
]]},
      {"11.6 Punctuation and emojis in every mode", [[
Punctuation and emojis are added in all of these modes:

1. Normal typing (Type with AI OFF): the word rules add punctuation and emojis to the words you spoke.

2. Direct Translation (AI OFF): the rules run on the translated text, using the rules of the target language.

3. Text Convert to English (AI OFF): the rules first read the words you actually spoke (for example Tamil words), because question words and mood words are recognized best in the original language. The commas, the ending mark and the emojis are then placed at the same word positions in the English-letter text. So a Tamil question still gets a question mark even though it is written in English letters.

4. AI mode (Type with AI ON, with or without translation or English letters): the AI adds punctuation itself. If any mark is still missing, the rules add it. If Use Emoji is ON and the AI did not add any emoji, the emoji word list adds some. If the AI already added emojis, they are kept as they are.

Switches:
- Auto Punctuation controls the commas and the ending marks.
- Use Emoji and Emoji Amount control the emojis.
]]},
    }},

    {"12. Troubleshooting", {
      {"12.1 Nothing is typed", [[
- Make sure the cursor is inside a text box before running the script.
- Check microphone permission for the accessibility service or app that runs the script.
- Check your internet connection. Speech recognition and AI need the internet.
- Make sure the Voice Dictation Language matches the language you actually speak.
]]},
      {"12.2 Type with AI does not work", [[
- Switch Type with AI to ON and press Save and Exit. It is saved only then.
- Open API Settings, paste your key and press Test API. Fix the problem shown, then press Save.
- Listen for "AI failed ..." after typing. The message tells you the reason.
- If quota is finished, wait or choose another model.
]]},
      {"12.3 The AI is slow", [[
- Choose gemini-2.5-flash-lite in API Settings and press Save.
- Use a stronger internet connection.
- Speak in shorter parts if your speech is very long.
- Avoid Pro models for dictation.
]]},
      {"12.4 The microphone stops while I pause", [[
Increase the waiting time inside the script: for example set SILENCE_END_MS to 3000 and SILENCE_POSSIBLE_MS to 2500.

Note: on some phones Google's speech recognition ignores these settings, so the result may not change.
]]},
      {"12.5 Typing is delayed after I stop", [[
- Decrease SILENCE_END_MS and SILENCE_POSSIBLE_MS (for example 1500 and 1000).
- If Type with AI is ON, the AI step adds a short delay. Use gemini-2.5-flash-lite.
- Check your internet speed.
]]},
      {"12.6 Messages you may hear", [[
- "Voice stopped!": speech recognition gave an error. Check microphone permission and internet, then try again.
- "AI failed ...": the AI could not answer, and normal typing was used. See lesson 3.9.
- "Please enter both words": in the dictionary editor, fill both Wrong word and Correct word.
- "No languages in dictionary": add a language first (lesson 7.3).
- "Enter the API key first": paste your key in API Settings.
]]},
    }},
  }

  local flat = {}
  local topicStart = {}
  for ti, topic in ipairs(topics) do
    topicStart[ti] = #flat + 1
    for li, pg in ipairs(topic[2]) do
      table.insert(flat, {
        ti = ti,
        li = li,
        n = #topic[2],
        topicTitle = topic[1],
        title = pg[1],
        text = pg[2]
      })
    end
  end
  local totalLessons = #flat

  local function wrapIndex(i)
    if i < 1 then return totalLessons end
    if i > totalLessons then return 1 end
    return i
  end

  local function openLessonDialog(startGlobal)
    local g = startGlobal

    local tv = TextView(service)
    tv.setTextSize(16)
    tv.setPadding(40, 30, 40, 30)

    local sc = ScrollView(service)
    sc.addView(tv)

    local lessonDlg = AlertDialog.Builder(service)
      .setTitle("Tutorial")
      .setView(sc)
      .setPositiveButton("Next", nil)
      .setNegativeButton("Previous", nil)
      .setNeutralButton("Back", nil)
      .create()

    local function showLesson(newG)
      g = wrapIndex(newG)
      _G.rdsTutorialPos = g
      local it = flat[g]
      lessonDlg.setTitle(tostring(it.title) .. "  (" .. tostring(it.li) .. "/" .. tostring(it.n) .. ")")
      tv.setText("Topic: " .. tostring(it.topicTitle) .. "\n\n" .. tostring(it.text))
      sc.scrollTo(0, 0)
      service.asyncSpeak(tostring(it.title))
    end

    prepareServiceDialog(lessonDlg)
    lessonDlg.show()

    local btnNext = lessonDlg.getButton(DialogInterface.BUTTON_POSITIVE)
    local btnPrev = lessonDlg.getButton(DialogInterface.BUTTON_NEGATIVE)

    btnNext.setOnClickListener{
      onClick = function(v)
        showLesson(g + 1)
      end
    }

    btnPrev.setOnClickListener{
      onClick = function(v)
        showLesson(g - 1)
      end
    }

    showLesson(g)
    doVibrate("start")
  end

  _G.rdsTutorialPos = nil

  local titles = ArrayList()
  for _, t in ipairs(topics) do
    titles.add(t[1])
  end

  local listView = ListView(service)
  listView.setAdapter(ArrayAdapter(service, android.R.layout.simple_list_item_1, titles))

  local dlg = AlertDialog.Builder(service)
    .setTitle("Tutorial - Select a topic")
    .setView(listView)
    .setPositiveButton("Next", nil)
    .setNegativeButton("Previous", nil)
    .setNeutralButton("Close", nil)
    .create()

  listView.setOnItemClickListener(AdapterView.OnItemClickListener{
    onItemClick = function(parent, view, position, id)
      local startAt = topicStart[position + 1]
      if startAt then
        openLessonDialog(startAt)
      end
    end
  })

  prepareServiceDialog(dlg)
  dlg.show()

  local listNext = dlg.getButton(DialogInterface.BUTTON_POSITIVE)
  local listPrev = dlg.getButton(DialogInterface.BUTTON_NEGATIVE)

  listNext.setOnClickListener{
    onClick = function(v)
      local base = _G.rdsTutorialPos
      if base then
        openLessonDialog(wrapIndex(base + 1))
      else
        openLessonDialog(1)
      end
    end
  }

  listPrev.setOnClickListener{
    onClick = function(v)
      local base = _G.rdsTutorialPos
      if base then
        openLessonDialog(wrapIndex(base - 1))
      else
        openLessonDialog(totalLessons)
      end
    end
  }

  doVibrate("start")
  service.asyncSpeak("Tutorial. Select a topic")
end

----------------------------------------------------------------
-- 4A-2. AI-only Query Mode: answer factual/general questions in dictation language
-- No topic/name dictionary. Gemini classifies intent and writes the answer.
----------------------------------------------------------------
local function geminiAnswerQuery(spokenText, srcLang, emojiEnabled, emojiLevel)
  local apiKey = trimStr(prefs.getString("gemini_api_key", ""))
  local model = trimStr(prefs.getString("gemini_model", DEFAULT_GEMINI_MODEL))
  if apiKey == "" then return nil, "API key is not set.", false end
  if model == "" then model = DEFAULT_GEMINI_MODEL end

  local languageName = getLanguageEnglishName(srcLang)
  local emojiInstruction = "Do not include emojis."
  if emojiEnabled then
    if emojiLevel == "Punctuation Only" then
      emojiInstruction = "Do not use emojis; use natural punctuation only."
    elseif emojiLevel == "Low Emoji Typing" or emojiLevel == "Low" then
      emojiInstruction = "Use only a few relevant emojis, sparingly."
    elseif emojiLevel == "High Emoji" or emojiLevel == "High" then
      emojiInstruction = "Use slightly more emojis than Medium: about two relevant emojis per meaningful clause, one near the start and one at the end. Never add an emoji after every word."
    else
      emojiInstruction = "Use one relevant emoji per meaningful phrase/clause, not per word. Split at commas, semicolons and sentence endings; keep it moderate and uncluttered."
    end
  end

  local instruction = "You are a voice-dictation query assistant that answers the user's actual request. The speech recognition language is " .. languageName .. ". " ..
    "Classify the user's utterance. If it asks a question or requests factual/general information, an explanation, a how-to answer, a definition, a history, information about a person/place/product/Android phone/technology, OR asks for a story, set answer=true and fulfill the request. " ..
    "IMPORTANT STORY RULE: When the user says things like tell me a story, I want a story, tell a story about [topic/person/animal], a funny story, love story, sad story, children's story, village story, adventure story, or a story with a moral, WRITE THE ACTUAL STORY itself. Do not explain what a story is, do not answer with advice about how to ask, and do not give a summary instead of the story. Use the topic, characters, mood, audience, language, and length requested by the user. If no length is specified, write a complete, engaging medium-length story with a clear beginning, middle, and ending. If the user asks for a short story, keep it short; if the user asks for a long story, make it longer. If the user asks for a moral, include it naturally at the end only when requested or appropriate. " ..
    "For example, requests for a short history of Mahatma Gandhi or information about an Android phone are information queries; a request to tell a story must produce the story itself. " ..
    "QUERY MODE MUST HANDLE ALL EXPLICIT QUESTIONS AND REQUESTS, not only factual questions. This includes asking for explanations, advice, recommendations, comparisons, translations, summaries, examples, instructions, creative writing, messages, birthday wishes, quotes, poems, captions, greetings, and any kind of story. Fulfil the actual request instead of rejecting it or routing it to another mode. For a requested message/quote/poem, create the requested content itself; for a story, write the story; for a question, answer it. Set answer=false ONLY when the utterance is plainly ordinary text being dictated for transcription and contains no question or request. If uncertain whether it is a request, treat it as a request and answer helpfully. " ..
    "When answer=true, respond in " .. languageName .. " using its proper script, unless the user explicitly requests another language. Match the requested format and length. Use correct grammar, spelling, capitalization, and natural punctuation. " ..
    "Output ONLY the requested final content: for story requests, output only the story; for factual questions, output only the answer. No introduction such as 'Here is the answer', no description of what you are doing, no labels, and no commentary in any language. " .. emojiInstruction .. " " ..
    "Return ONLY valid JSON with exactly these keys: {\"answer\":true/false,\"text\":\"...\"}. Escape JSON string characters correctly. No Markdown fences or extra keys."

  local body = '{"systemInstruction":{"parts":[{"text":' .. tostring(JSONObject.quote(instruction)) .. '}]},' ..
    '"contents":[{"role":"user","parts":[{"text":' .. tostring(JSONObject.quote(tostring(spokenText or ""))) .. '}]}],' ..
    '"generationConfig":{"temperature":0.25,"responseMimeType":"application/json"}}'

  local code, resp = geminiHttp("POST", "models/" .. model .. ":generateContent", apiKey, body, 25000)
  if code ~= 200 then return nil, describeGeminiError(code, resp, model), false end

  local raw = ""
  pcall(function()
    local root = JSONObject(resp)
    local candidates = root.optJSONArray("candidates")
    if candidates and candidates.length() > 0 then
      local content = candidates.getJSONObject(0).optJSONObject("content")
      local parts = content and content.optJSONArray("parts")
      if parts then
        for i = 0, parts.length() - 1 do raw = raw .. tostring(parts.getJSONObject(i).optString("text", "")) end
      end
    end
  end)
  raw = trimStr(raw):gsub("^```json", ""):gsub("^```", ""):gsub("```$", "")
  local ok, parsed = pcall(function() return JSONObject(raw) end)
  if not ok or not parsed then return nil, "Could not read query response.", false end
  local shouldAnswer = parsed.optBoolean("answer", false)
  local output = trimStr(parsed.optString("text", ""))
  if shouldAnswer and output ~= "" then return output, nil, true end
  return nil, nil, false
end

----------------------------------------------------------------
----------------------------------------------------------------
-- Provider-aware Messages/Quotes and Query Mode (Gemini or Groq)
----------------------------------------------------------------
local function groqStructuredRequest(spokenText, srcLang, emojiEnabled, emojiLevel, messageLength, requestType)
  local apiKey = trimStr(prefs.getString("groq_api_key", ""))
  local model = trimStr(prefs.getString("groq_model", DEFAULT_GROQ_MODEL))
  if apiKey == "" then return nil, "Groq API key is not set.", false end
  if model == "" then model = DEFAULT_GROQ_MODEL end
  local languageName = getLanguageEnglishName(srcLang)
  local emojiInstruction = "Do not include emojis."
  if emojiEnabled then
    if emojiLevel == "Punctuation Only" then emojiInstruction = "Do not include emojis; use natural punctuation only."
    elseif emojiLevel == "Low Emoji Typing" or emojiLevel == "Low" then emojiInstruction = "Use only a few highly relevant emojis, sparingly."
    elseif emojiLevel == "High Emoji" or emojiLevel == "High" then emojiInstruction = "Use clearly more emojis than Medium: aim for two relevant emojis per meaningful clause and three for longer clauses (beginning, optional middle for long clauses, and end). Never add an emoji after every word."
    else emojiInstruction = "Use one relevant emoji per meaningful phrase/clause, not per word. Split at commas, semicolons and sentence endings; keep it moderate and uncluttered." end
  end
  local taskInstruction
  local keyName
  if requestType == "query" then
    keyName = "answer"
    taskInstruction = "QUERY MODE MUST HANDLE ALL EXPLICIT QUESTIONS AND REQUESTS, not only factual questions. If the utterance asks for information, an explanation, definition, how-to, history, recommendations, comparison, translation, summary, examples, advice, or anything about a person, place, product, Android phone, technology, or any topic, set answer=true and fulfil the request. Also set answer=true for creative requests such as a story, message, birthday wish, quote, poem, caption, greeting, attitude message, or other requested text. STORY RULE: when asked for a story, write the actual complete story, not an explanation or summary; follow the requested topic, mood, language and length, and use a complete beginning, middle and ending unless the user requests a different length. For messages/quotes/poems, output the requested content itself. Set answer=false ONLY if the utterance is plainly ordinary text being dictated for transcription and contains no question or request. If uncertain, treat it as a request and answer helpfully. When answer=true, output only the requested final content, without introduction, labels, description or commentary."
  else
    keyName = "generate"
    local lengthInstruction = "Write a medium-length ready-to-send message."
    if messageLength == "Short Message" then lengthInstruction = "Write a short ready-to-send message."
    elseif messageLength == "Long Message" then lengthInstruction = "Write a long, detailed ready-to-send message." end
    taskInstruction = "If the utterance explicitly asks to CREATE/WRITE/GENERATE a message, wishes, quote, poem, caption, greeting, attitude message, sad message, birthday wish, or similar ready-to-send creative text, set generate=true and write it. If it merely dictates text or mentions a topic without asking to create content, set generate=false and text empty. " .. lengthInstruction .. " Output ONLY the message itself, no title unless requested, no introduction, description, explanation, labels, or commentary."
  end
  local instruction = "You are an assistant for voice dictation. Speech recognition language is " .. languageName .. ". " .. taskInstruction .. " Respond in " .. languageName .. " using its proper script unless another language is explicitly requested. Use correct grammar, spelling, capitalization, and natural punctuation. " .. emojiInstruction .. " Return ONLY valid JSON with exactly keys {\"" .. keyName .. "\":true/false,\"text\":\"...\"}. Escape JSON correctly. No Markdown fences or extra keys."
  local body = '{"model":' .. tostring(JSONObject.quote(model)) .. ',"messages":[{"role":"system","content":' .. tostring(JSONObject.quote(instruction)) .. '},{"role":"user","content":' .. tostring(JSONObject.quote(tostring(spokenText or ""))) .. '}],"temperature":0.25,"max_tokens":1800,"response_format":{"type":"json_object"}}'
  local code, resp = groqHttp("POST", "chat/completions", apiKey, body, 25000)
  if code ~= 200 then return nil, describeGroqError(code, resp, model), false end
  local raw = ""
  pcall(function()
    local root = JSONObject(resp)
    local choices = root.optJSONArray("choices")
    if choices and choices.length() > 0 then
      local msg = choices.getJSONObject(0).optJSONObject("message")
      if msg then raw = tostring(msg.optString("content", "")) end
    end
  end)
  raw = trimStr(raw):gsub("^```json", ""):gsub("^```", ""):gsub("```$", "")
  local ok, parsed = pcall(function() return JSONObject(raw) end)
  if not ok or not parsed then return nil, "Could not read Groq response.", false end
  local accepted = parsed.optBoolean(keyName, false)
  local output = trimStr(parsed.optString("text", ""))
  if accepted and output ~= "" then return output, nil, true end
  return nil, nil, false
end

local function selectedGenerateMessageOrQuote(spokenText, srcLang, emojiEnabled, emojiLevel, messageLength)
  if getActiveAIProvider() == "Groq" then
    return groqStructuredRequest(spokenText, srcLang, emojiEnabled, emojiLevel, messageLength, "creative")
  end
  return geminiGenerateMessageOrQuote(spokenText, srcLang, emojiEnabled, emojiLevel, messageLength)
end

local function selectedAnswerQuery(spokenText, srcLang, emojiEnabled, emojiLevel)
  if getActiveAIProvider() == "Groq" then
    return groqStructuredRequest(spokenText, srcLang, emojiEnabled, emojiLevel, "Medium Message", "query")
  end
  return geminiAnswerQuery(spokenText, srcLang, emojiEnabled, emojiLevel)
end

----------------------------------------------------------------
local function openSettingsDialog()
  mainHandler.post(Runnable{
    run = function()
      local currentSrcCode = prefs.getString("source_lang_code", "ta-IN")
      local currentSrcName = prefs.getString("source_lang_name", "Tamil (India)")
      local currentTgtCode = prefs.getString("target_lang_code", "en-US")
      local currentTgtName = prefs.getString("target_lang_name", "English (United States)")

      local isAIEnabled = prefs.getBoolean("ai_typing_enabled", false)
      local isMessagesQuotesEnabled = prefs.getBoolean("messages_quotes_enabled", false)
      local isQueryModeEnabled = prefs.getBoolean("query_mode_enabled", false)
      local currentMessageLength = tostring(prefs.getString("messages_quotes_length", "Medium Message"))
      local isTranslateEnabled = prefs.getBoolean("translate_enabled", false)
      local isConvertEnglishEnabled = prefs.getBoolean("convert_english_enabled", true)
      local isDictEnabled = prefs.getBoolean("dictionary_enabled", true)
      local isVibEnabled = prefs.getBoolean("vibration_feedback", true)
      local isEmojiEnabled = prefs.getBoolean("use_emoji", false)
      local isPunctEnabled = prefs.getBoolean("auto_punctuation", true)
      local currentEmojiLevel = tostring(prefs.getString("emoji_level", "Medium Emoji"))

      local layout = LinearLayout(service)
      layout.setOrientation(LinearLayout.VERTICAL)
      layout.setPadding(40, 30, 40, 30)

      -- 0. Type with AI ON/OFF Button + API Settings Button
      local btnToggleAI = Button(service)
      btnToggleAI.setText("Type with AI: " .. (isAIEnabled and "ON" or "OFF"))
      layout.addView(btnToggleAI)

      local btnMessagesQuotes, messageLengthLabel, messageLengthSpinner, btnQueryMode

      btnToggleAI.setOnClickListener{
        onClick = function(v)
          isAIEnabled = not isAIEnabled
          btnToggleAI.setText("Type with AI: " .. (isAIEnabled and "ON" or "OFF"))
          -- Keep AI-only controls in place below the emoji combo box; disable them when AI is OFF.
          btnMessagesQuotes.setEnabled(isAIEnabled)
          messageLengthLabel.setEnabled(isAIEnabled)
          messageLengthSpinner.setEnabled(isAIEnabled)
          btnQueryMode.setEnabled(isAIEnabled)
          pcall(function()
            btnMessagesQuotes.setAlpha(isAIEnabled and 1.0 or 0.45)
            messageLengthLabel.setAlpha(isAIEnabled and 1.0 or 0.45)
            messageLengthSpinner.setAlpha(isAIEnabled and 1.0 or 0.45)
            btnQueryMode.setAlpha(isAIEnabled and 1.0 or 0.45)
          end)
          if isAIEnabled then
            if activeAIKey() == "" then
              service.asyncSpeak("ON. Please set the selected AI provider API key in API Settings.")
            else
              service.asyncSpeak("ON")
            end
          else
            service.asyncSpeak("OFF")
          end
        end
      }

      local btnApiSettings = Button(service)
      btnApiSettings.setText("AI Settings (Gemini / Groq)")
      layout.addView(btnApiSettings)

      btnApiSettings.setOnClickListener{
        onClick = function(v)
          openApiSettingsDialog()
        end
      }

      local tvSpace0 = TextView(service)
      tvSpace0.setText("\n")
      layout.addView(tvSpace0)

      -- 1. Voice Dictation Language Button
      local srcLabel = TextView(service)
      srcLabel.setText("Voice Dictation Language:")
      srcLabel.setTextSize(16)
      layout.addView(srcLabel)

      local btnSelectSrc = Button(service)
      btnSelectSrc.setText(currentSrcName .. " [" .. currentSrcCode .. "]")
      layout.addView(btnSelectSrc)

      local tvSpace1 = TextView(service)
      tvSpace1.setText("\n")
      layout.addView(tvSpace1)

      -- 2. Direct Translation ON/OFF Button & Target Lang Button
      local btnToggleTranslate = Button(service)
      btnToggleTranslate.setText("Direct Translation: " .. (isTranslateEnabled and "ON" or "OFF"))
      layout.addView(btnToggleTranslate)

      local btnSelectTgt = Button(service)
      btnSelectTgt.setText(currentTgtName .. " [" .. currentTgtCode .. "]")
      btnSelectTgt.setEnabled(isTranslateEnabled)
      layout.addView(btnSelectTgt)

      btnToggleTranslate.setOnClickListener{
        onClick = function(v)
          isTranslateEnabled = not isTranslateEnabled
          btnToggleTranslate.setText("Direct Translation: " .. (isTranslateEnabled and "ON" or "OFF"))
          btnSelectTgt.setEnabled(isTranslateEnabled)
          if isTranslateEnabled then
            service.asyncSpeak("ON")
          else
            service.asyncSpeak("OFF")
          end
        end
      }

      btnSelectSrc.setOnClickListener{
        onClick = function(v)
          openLanguageSearchDialog("Select Dictation Language", currentSrcCode, function(name, tag, fullStr)
            currentSrcName = name
            currentSrcCode = tag
            btnSelectSrc.setText(fullStr)
          end)
        end
      }

      btnSelectTgt.setOnClickListener{
        onClick = function(v)
          openLanguageSearchDialog("Select Target Language", currentTgtCode, function(name, tag, fullStr)
            currentTgtName = name
            currentTgtCode = tag
            btnSelectTgt.setText(fullStr)
          end)
        end
      }

      local tvSpace2 = TextView(service)
      tvSpace2.setText("\n")
      layout.addView(tvSpace2)

      -- 3. Convert English ON/OFF Button
      local btnToggleConvert = Button(service)
      btnToggleConvert.setText("Text Convert to English: " .. (isConvertEnglishEnabled and "ON" or "OFF"))
      layout.addView(btnToggleConvert)

      btnToggleConvert.setOnClickListener{
        onClick = function(v)
          isConvertEnglishEnabled = not isConvertEnglishEnabled
          btnToggleConvert.setText("Text Convert to English: " .. (isConvertEnglishEnabled and "ON" or "OFF"))
          if isConvertEnglishEnabled then
            service.asyncSpeak("ON")
          else
            service.asyncSpeak("OFF")
          end
        end
      }

      -- 4. Use Dictionary ON/OFF Button
      local btnToggleDict = Button(service)
      btnToggleDict.setText("Use Dictionary: " .. (isDictEnabled and "ON" or "OFF"))
      layout.addView(btnToggleDict)

      btnToggleDict.setOnClickListener{
        onClick = function(v)
          isDictEnabled = not isDictEnabled
          btnToggleDict.setText("Use Dictionary: " .. (isDictEnabled and "ON" or "OFF"))
          if isDictEnabled then
            service.asyncSpeak("ON")
          else
            service.asyncSpeak("OFF")
          end
        end
      }

      -- 5. ComboBox (Spinner) for Dictionary Mode & Button to Open Dictionary Editor
      local dictModeLabel = TextView(service)
      dictModeLabel.setText("Dictionary Mode:")
      dictModeLabel.setTextSize(16)
      layout.addView(dictModeLabel)

      local dictModeList = ArrayList()
      dictModeList.add("Normal Typing")
      dictModeList.add("English Converter")

      local dictModeSpinner = Spinner(service)
      local dictModeAdapter = ArrayAdapter(service, android.R.layout.simple_spinner_dropdown_item, dictModeList)
      dictModeSpinner.setAdapter(dictModeAdapter)
      layout.addView(dictModeSpinner)

      local btnOpenDict = Button(service)
      btnOpenDict.setText("Manage Dictionary Words")
      layout.addView(btnOpenDict)

      btnOpenDict.setOnClickListener{
        onClick = function(v)
          local selectedMode = tostring(dictModeSpinner.getSelectedItem())
          if selectedMode == "Normal Typing" then
            showDictionaryLanguagesDialog("normal")
          else
            showDictionaryLanguagesDialog("convert")
          end
        end
      }

      local tvSpace3 = TextView(service)
      tvSpace3.setText("\n")
      layout.addView(tvSpace3)

      -- 6. Vibration Feedback ON/OFF Button
      local btnToggleVib = Button(service)
      btnToggleVib.setText("Vibration Feedback: " .. (isVibEnabled and "ON" or "OFF"))
      layout.addView(btnToggleVib)

      btnToggleVib.setOnClickListener{
        onClick = function(v)
          isVibEnabled = not isVibEnabled
          btnToggleVib.setText("Vibration Feedback: " .. (isVibEnabled and "ON" or "OFF"))
          if isVibEnabled then
            service.asyncSpeak("ON")
          else
            service.asyncSpeak("OFF")
          end
        end
      }

      local tvSpace4 = TextView(service)
      tvSpace4.setText("\n")
      layout.addView(tvSpace4)

      -- Auto punctuation is controlled by the Emoji Amount combo box.


      local tvSpace5 = TextView(service)
      tvSpace5.setText("\n")
      layout.addView(tvSpace5)

      -- 7. Use Emoji ON/OFF Button + Emoji Amount Spinner (AI mode and Normal mode)
      local btnToggleEmoji = Button(service)
      btnToggleEmoji.setText("Typing Mode: " .. (isEmojiEnabled and "ON" or "OFF"))
      layout.addView(btnToggleEmoji)

      local emojiLabel = TextView(service)
      emojiLabel.setText("Typing Style (AI and Normal typing):")
      emojiLabel.setTextSize(16)
      layout.addView(emojiLabel)

      local emojiList = ArrayList()
      emojiList.add("Punctuation Only")
      emojiList.add("Low Emoji Typing")
      emojiList.add("Medium Emoji")
      emojiList.add("High Emoji")

      local emojiSpinner = Spinner(service)
      local emojiAdapter = ArrayAdapter(service, android.R.layout.simple_spinner_dropdown_item, emojiList)
      emojiSpinner.setAdapter(emojiAdapter)
      layout.addView(emojiSpinner)

      -- AI-only controls are placed immediately below the Emoji/Typing Style combo box: Message and Quotes, length, then Query Mode.
      btnMessagesQuotes = Button(service)
      btnMessagesQuotes.setText("Message and Quotes: " .. (isMessagesQuotesEnabled and "ON" or "OFF"))
      btnMessagesQuotes.setEnabled(isAIEnabled)
      pcall(function() btnMessagesQuotes.setAlpha(isAIEnabled and 1.0 or 0.45) end)
      layout.addView(btnMessagesQuotes)
      btnMessagesQuotes.setOnClickListener{
        onClick = function(v)
          isMessagesQuotesEnabled = not isMessagesQuotesEnabled
          btnMessagesQuotes.setText("Message and Quotes: " .. (isMessagesQuotesEnabled and "ON" or "OFF"))
          service.asyncSpeak("Message and Quotes " .. (isMessagesQuotesEnabled and "ON" or "OFF"))
        end
      }

      messageLengthLabel = TextView(service)
      messageLengthLabel.setText("Message Length:")
      messageLengthLabel.setTextSize(16)
      messageLengthLabel.setEnabled(isAIEnabled)
      pcall(function() messageLengthLabel.setAlpha(isAIEnabled and 1.0 or 0.45) end)
      layout.addView(messageLengthLabel)

      local messageLengthList = ArrayList()
      messageLengthList.add("Short Message")
      messageLengthList.add("Medium Message")
      messageLengthList.add("Long Message")
      messageLengthSpinner = Spinner(service)
      local messageLengthAdapter = ArrayAdapter(service, android.R.layout.simple_spinner_dropdown_item, messageLengthList)
      messageLengthSpinner.setAdapter(messageLengthAdapter)
      messageLengthSpinner.setEnabled(isAIEnabled)
      pcall(function() messageLengthSpinner.setAlpha(isAIEnabled and 1.0 or 0.45) end)
      layout.addView(messageLengthSpinner)
      for i = 0, messageLengthList.size() - 1 do
        if tostring(messageLengthList.get(i)) == currentMessageLength then
          messageLengthSpinner.setSelection(i)
          break
        end
      end

      -- Query Mode is AI-only and sits below Message and Quotes and Message Length.
      btnQueryMode = Button(service)
      btnQueryMode.setText("Query Mode: " .. (isQueryModeEnabled and "ON" or "OFF"))
      btnQueryMode.setEnabled(isAIEnabled)
      pcall(function() btnQueryMode.setAlpha(isAIEnabled and 1.0 or 0.45) end)
      layout.addView(btnQueryMode)
      btnQueryMode.setOnClickListener{
        onClick = function(v)
          isQueryModeEnabled = not isQueryModeEnabled
          btnQueryMode.setText("Query Mode: " .. (isQueryModeEnabled and "ON" or "OFF"))
          service.asyncSpeak("Query Mode " .. (isQueryModeEnabled and "ON" or "OFF"))
        end
      }

      local normalizedEmojiLevel = currentEmojiLevel
      if normalizedEmojiLevel == "Low" then normalizedEmojiLevel = "Low Emoji Typing" end
      if normalizedEmojiLevel == "Medium" then normalizedEmojiLevel = "Medium Emoji" end
      if normalizedEmojiLevel == "High" then normalizedEmojiLevel = "High Emoji" end
      local emojiSelectionFound = false
      for i = 0, emojiList.size() - 1 do
        if tostring(emojiList.get(i)) == normalizedEmojiLevel then
          emojiSpinner.setSelection(i)
          emojiSelectionFound = true
          break
        end
      end
      if not emojiSelectionFound then emojiSpinner.setSelection(0) end

      btnToggleEmoji.setOnClickListener{
        onClick = function(v)
          isEmojiEnabled = not isEmojiEnabled
          btnToggleEmoji.setText("Typing Mode: " .. (isEmojiEnabled and "ON" or "OFF"))
          if isEmojiEnabled then
            service.asyncSpeak("ON")
          else
            service.asyncSpeak("OFF")
          end
        end
      }

      local scroll = ScrollView(service)
      scroll.addView(layout)

      local mainDialog = AlertDialog.Builder(service)
        .setTitle("RDS Voice Dictation")
        .setView(scroll)
        .setPositiveButton("Save and Exit", function()
          local selEmojiItem = emojiSpinner.getSelectedItem()
          local selEmoji = selEmojiItem and tostring(selEmojiItem) or "Medium"

          local editor = prefs.edit()
          editor.putString("source_lang_code", currentSrcCode)
          editor.putString("source_lang_name", currentSrcName)
          editor.putString("target_lang_code", currentTgtCode)
          editor.putString("target_lang_name", currentTgtName)
          editor.putBoolean("ai_typing_enabled", isAIEnabled)
          editor.putBoolean("messages_quotes_enabled", isMessagesQuotesEnabled)
          editor.putBoolean("query_mode_enabled", isQueryModeEnabled)
          local selectedMessageLengthItem = messageLengthSpinner.getSelectedItem()
          editor.putString("messages_quotes_length", selectedMessageLengthItem and tostring(selectedMessageLengthItem) or "Medium Message")
          editor.putBoolean("translate_enabled", isTranslateEnabled)
          editor.putBoolean("convert_english_enabled", isConvertEnglishEnabled)
          editor.putBoolean("dictionary_enabled", isDictEnabled)
          editor.putBoolean("vibration_feedback", isVibEnabled)
          editor.putBoolean("use_emoji", isEmojiEnabled)
          editor.putBoolean("auto_punctuation", isPunctEnabled)
          editor.putString("emoji_level", selEmoji)
          editor.apply()

          service.asyncSpeak("Settings saved.")
        end)
        .setNegativeButton("Cancel", nil)
        .setNeutralButton("Telegram Group", function()
          local telegramIntent = Intent(Intent.ACTION_VIEW, Uri.parse("https://t.me/+vuZ8soVRsIMxYjBl"))
          telegramIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
          service.startActivity(telegramIntent)
        end)
        .create()

      mainDialog.setOnShowListener(DialogInterface.OnShowListener{
        onShow = function(d)
          pcall(function()
            local btnSave = mainDialog.getButton(DialogInterface.BUTTON_POSITIVE)
            local btnCancel = mainDialog.getButton(DialogInterface.BUTTON_NEGATIVE)
            local btnTelegram = mainDialog.getButton(DialogInterface.BUTTON_NEUTRAL)

            if btnSave and btnCancel and btnTelegram then
              local parentLayout = btnSave.getParent()
              if parentLayout and parentLayout.removeAllViews then
                local barOk = pcall(function()
                  local row = LinearLayout(service)
                  row.setOrientation(LinearLayout.HORIZONTAL)

                  parentLayout.removeAllViews()

                  -- Bottom buttons in reversed order: Telegram Group | Cancel | Save and Exit. Tutorial removed.
                  local allBtns = {btnTelegram, btnCancel, btnSave}
                  for _, b in ipairs(allBtns) do
                    pcall(function()
                      b.setMinWidth(0)
                      b.setMinimumWidth(0)
                      b.setTextSize(12)
                    end)
                    row.addView(b, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1.0))
                  end

                  parentLayout.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
                end)

                if not barOk then
                  pcall(function()
                    for _, b in ipairs({btnTelegram, btnCancel, btnSave}) do
                      local par = b.getParent()
                      if par then par.removeView(b) end
                    end
                    parentLayout.removeAllViews()
                    parentLayout.addView(btnTelegram)
                    parentLayout.addView(btnCancel)
                    parentLayout.addView(btnSave)
                  end)
                end
              end
            end
          end)
        end
      })

      prepareServiceDialog(mainDialog)
      mainDialog.show()
    end
  })
end

----------------------------------------------------------------
----------------------------------------------------------------
local function translateOnline(sourceText, srcLang, tgtLang)
  local success, result = pcall(function()
    local shortSrc = srcLang:match("^([%a]+)") or srcLang
    local shortTgt = tgtLang:match("^([%a]+)") or tgtLang
    local encodedText = URLEncoder.encode(sourceText, "UTF-8")
    local urlStr = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=" .. shortSrc .. "&tl=" .. shortTgt .. "&dt=t&q=" .. encodedText
    local url = URL(urlStr)
    local conn = url.openConnection()
    conn.setRequestMethod("GET")
    conn.setRequestProperty("User-Agent", "Mozilla/5.0")
    conn.setConnectTimeout(5000)
    conn.setReadTimeout(5000)

    local reader = BufferedReader(InputStreamReader(conn.getInputStream(), "UTF-8"))
    local response = ""
    local line = reader.readLine()
    while line ~= nil do
      response = response .. line
      line = reader.readLine()
    end
    reader.close()

    local jsonArray = JSONArray(response)
    local sentencesArray = jsonArray.getJSONArray(0)
    local fullTranslatedText = ""

    for i = 0, sentencesArray.length() - 1 do
      local singleSentence = sentencesArray.getJSONArray(i)
      fullTranslatedText = fullTranslatedText .. singleSentence.getString(0)
    end

    if fullTranslatedText ~= "" then return fullTranslatedText end
    return sourceText
  end)

  if success and result then return result else return sourceText end
end

local function fixGrammarOnline(inputText, langCode)
  if not inputText or inputText == "" then return "" end
  if not langCode:find("^en") then return inputText end

  local success, result = pcall(function()
    local postData = "text=" .. URLEncoder.encode(inputText, "UTF-8") .. "&language=en-US"
    local url = URL("https://api.languagetool.org/v2/check")
    local conn = url.openConnection()
    conn.setRequestMethod("POST")
    conn.setDoOutput(true)
    conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
    conn.setRequestProperty("User-Agent", "Mozilla/5.0")
    conn.setConnectTimeout(6000)
    conn.setReadTimeout(6000)

    local out = DataOutputStream(conn.getOutputStream())
    out.writeBytes(postData)
    out.flush()
    out.close()

    local reader = BufferedReader(InputStreamReader(conn.getInputStream(), "UTF-8"))
    local sb = StringBuilder()
    local line = reader.readLine()
    while line ~= nil do
      sb.append(line)
      line = reader.readLine()
    end
    reader.close()

    local json = JSONObject(sb.toString())
    local matches = json.getJSONArray("matches")
    local javaStr = StringBuilder(inputText)

    for i = matches.length() - 1, 0, -1 do
      local match = matches.getJSONObject(i)
      local offset = match.getInt("offset")
      local length = match.getInt("length")
      local replacements = match.getJSONArray("replacements")

      if replacements.length() > 0 then
        local bestReplacement = replacements.getJSONObject(0).getString("value")
        javaStr.replace(offset, offset + length, bestReplacement)
      end
    end

    return javaStr.toString()
  end)

  if success and result and result ~= "" then
    return tostring(result)
  else
    return inputText
  end
end

----------------------------------------------------------------
----------------------------------------------------------------
local function formatAndAppendSymbol(text, symbolChoice)
  if not text or text == "" then return "" end
  
  text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
  text = text:gsub("^%s*(%l)", string.upper)
  if prefs.getBoolean("auto_punctuation", true) then
    text = text:gsub(",+$", ""):match("^%s*(.-)%s*$")
  else
    text = text:gsub("[%.,]+$", ""):match("^%s*(.-)%s*$")
  end

  local endingStr = " "
  if symbolChoice == "Space" then
    endingStr = " "
  elseif symbolChoice == "Comma" then
    endingStr = ", "
  elseif symbolChoice == "Full Stop" then
    endingStr = ". "
  elseif symbolChoice == "New Line" then
    endingStr = "\n"
  elseif symbolChoice == "Full Stop + New Line" then
    endingStr = ".\n"
  end

  return text .. endingStr
end

local function formatAIText(text)
  text = trimStr(text)
  if text == "" then return "" end
  return text .. " "
end

----------------------------------------------------------------
----------------------------------------------------------------
-- Semantic emojis are generated by Gemini from context; no hard-coded word/category dictionary.
local emojiWordMap = {}
local emojiMoodMap = {}

local englishQuestionStarts = {"what", "why", "how", "when", "where", "who", "which", "whose"}
local tamilQuestionWords = {"喈庎喁嵿", "喈忇喁�", "喈庎喁嵿喈熰", "喈庎喁嵿喁嬥喁�", "喈庎畽喁嵿畷喁�", "喈庎畽喁嵿畷", "喈喈班瘝", "喈庎喁�", "喈庎喁嵿喈赤喁�", "喈庎喁嵿喈┼瘓", "喈庎喁嵿喁�", "喈庎喁嵿"}

local function escapeLuaPattern(w)
  return (w:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function findEnglishWord(lowerText, w)
  return lowerText:find("%f[%w]" .. escapeLuaPattern(w) .. "%f[%W]")
end

local function findTamilWord(lowerText, w, wholeWord, startInit)
  local n = #lowerText
  local init = startInit or 1
  while true do
    local s, e = lowerText:find(w, init, true)
    if not s then return nil end
    local startOk = (s == 1) or (lowerText:sub(s - 1, s - 1):match("[%s%p]") ~= nil)
    if startOk then
      if wholeWord then
        if e == n or lowerText:sub(e + 1, e + 1):match("[%s%p]") then
          return s, e
        end
      else
        while e < n and not lowerText:sub(e + 1, e + 1):match("[%s%p]") do
          e = e + 1
        end
        return s, e
      end
    end
    init = s + 1
  end
end

local function findEntryMatch(lowerText, entry)
  local bestS, bestE = nil, nil
  for _, w in ipairs(entry[2]) do
    local s, e = findEnglishWord(lowerText, w)
    if s and (not bestS or (e - s) > (bestE - bestS)) then
      bestS, bestE = s, e
    end
  end
  for _, w in ipairs(entry[3]) do
    local s, e = findTamilWord(lowerText, w, false)
    if s and (not bestS or (e - s) > (bestE - bestS)) then
      bestS, bestE = s, e
    end
  end
  return bestS, bestE
end

local function addInlineEmojis(text, maxCount)
  local lowerText = text:lower()
  local cands = {}

  for _, entry in ipairs(emojiWordMap) do
    local emoji = entry[1]
    if not text:find(emoji, 1, true) then
      local s, e = findEntryMatch(lowerText, entry)
      if s then
        table.insert(cands, {s = s, e = e, len = e - s, emoji = emoji})
      end
    end
  end

  if #cands == 0 then return text end

  table.sort(cands, function(a, b)
    if a.len ~= b.len then return a.len > b.len end
    return a.s < b.s
  end)

  local accepted = {}
  for _, c in ipairs(cands) do
    local overlap = false
    for _, a in ipairs(accepted) do
      if not (c.e < a.s or c.s > a.e) then
        overlap = true
        break
      end
    end
    if not overlap then table.insert(accepted, c) end
  end

  table.sort(accepted, function(a, b) return a.s < b.s end)
  while #accepted > maxCount do
    table.remove(accepted)
  end

  for i = #accepted, 1, -1 do
    local c = accepted[i]
    local pe = c.e
    while pe < #text and text:sub(pe + 1, pe + 1):match("[,%.!%?;:]") do
      pe = pe + 1
    end
    text = text:sub(1, pe) .. " " .. c.emoji .. text:sub(pe + 1)
  end
  return text
end

local function looksLikeQuestion(segment, lowerSeg)
  if segment:find("?", 1, true) then return true end

  local first = lowerSeg:match("^%s*(%a+)")
  if first then
    for _, q in ipairs(englishQuestionStarts) do
      if first == q then return true end
    end
  end

  for _, q in ipairs(tamilQuestionWords) do
    if findTamilWord(lowerSeg, q, true) then return true end
  end
  return false
end

local function pickMoodEmoji(segment)
  local lowerSeg = segment:lower()
  local scored = {}

  for idx, entry in ipairs(emojiMoodMap) do
    local emoji = entry[1]
    if not segment:find(emoji, 1, true) then
      local score = 0
      for _, w in ipairs(entry[2]) do
        if findEnglishWord(lowerSeg, w) then score = score + 1 end
      end
      for _, w in ipairs(entry[3]) do
        if findTamilWord(lowerSeg, w, false) then score = score + 1 end
      end
      if score > 0 then
        table.insert(scored, {emoji = emoji, score = score, order = idx})
      end
    end
  end

  if looksLikeQuestion(segment, lowerSeg) and not segment:find("馃", 1, true) then
    table.insert(scored, {emoji = "馃", score = 2, order = 0})
  end

  if #scored == 0 then return nil end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.order < b.order
  end)
  return scored[1].emoji
end

-- Add emojis at meaningful clause boundaries, never after every word.
local function addClauseEmojiDensity(text, level)
  local trimmedAll = tostring(text or ""):match("^%s*(.-)%s*$")
  if not trimmedAll or trimmedAll == "" then return text end
  local out = {}
  local clauseCount = 0
  local maxClauses = 12
  for seg in trimmedAll:gmatch("[^,;%.!%?]+[,;%.!%?]*") do
    local piece = seg:match("^%s*(.-)%s*$")
    if piece and piece ~= "" then
      clauseCount = clauseCount + 1
      local body, delim = piece:match("^(.-)([,;%.!%?]*)$")
      body = (body or piece):gsub("%s+$", "")
      delim = delim or ""
      if clauseCount <= maxClauses and body ~= "" then
        local mood = pickMoodEmoji(body) or "馃檪"
        if level == "High" then
          local words = {}
          for word in body:gmatch("%S+") do words[#words + 1] = word end
          if #words >= 7 then
            local mid = math.max(2, math.floor(#words / 2))
            words[mid] = words[mid] .. " 馃挮"
            body = table.concat(words, " ")
          end
          body = "鉁� " .. body
        end
        if delim:find("[,;]", 1) then
          body = body .. " " .. mood .. delim
        elseif delim ~= "" then
          body = body .. delim .. " " .. mood
        else
          body = body .. " " .. mood
        end
      else
        body = body .. delim
      end
      table.insert(out, body)
    end
  end
  if #out == 0 then return text end
  return table.concat(out, " "):gsub("%s+([,;%.!%?])", "%1"):gsub("%s+", " ")
end

-- Low mode remains sparse: at most one emoji at each sentence end.
local function addSentenceEndEmojis(text, level)
  local trimmedAll = tostring(text or ""):match("^%s*(.-)%s*$")
  if not trimmedAll or trimmedAll == "" then return text end
  local out = {}
  for seg in trimmedAll:gmatch("[^%.!%?]+[%.!%?]*") do
    local piece = seg:match("^%s*(.-)%s*$")
    if piece and piece ~= "" then
      local emoji = pickMoodEmoji(piece) or "馃檪"
      if not piece:find(emoji, 1, true) then
        if piece:match("[%.!%?]$") then piece = piece .. " " .. emoji else piece = piece .. " " .. emoji end
      end
      table.insert(out, piece)
    end
  end
  if #out == 0 then return text end
  return table.concat(out, " ")
end

local function addEmojisToNormalText(text)
  if not text or text == "" then return text end
  if not prefs.getBoolean("use_emoji", false) then return text end
  local level = tostring(prefs.getString("emoji_level", "Medium Emoji"))
  if level == "None" or level == "Punctuation Only" then return text end
  if level == "Low Emoji Typing" then level = "Low" end
  if level == "Medium Emoji" then level = "Medium" end
  if level == "High Emoji" then level = "High" end

  if level == "Low" then
    -- Keep the existing Low behaviour: one matching emoji at most.
    return addInlineEmojis(text, 1)
  elseif level == "Medium" then
    -- Medium: one context-relevant emoji per meaningful clause, not per word.
    return addClauseEmojiDensity(text, "Medium")
  elseif level == "High" then
    -- High: more than Medium, but still clause-based rather than word-by-word.
    return addClauseEmojiDensity(text, "High")
  end
  return text
end

local function stripEmojiCharacters(text)
  if not text or text == "" then return text end
  local out = {}
  local i = 1
  while i <= #text do
    local b1 = text:byte(i)
    local cp, n = b1, 1
    if b1 < 128 then
      cp, n = b1, 1
    elseif b1 < 224 and i + 1 <= #text then
      cp = (b1 - 192) * 64 + ((text:byte(i + 1) or 128) - 128); n = 2
    elseif b1 < 240 and i + 2 <= #text then
      cp = (b1 - 224) * 4096 + ((text:byte(i + 1) or 128) - 128) * 64 + ((text:byte(i + 2) or 128) - 128); n = 3
    elseif i + 3 <= #text then
      cp = (b1 - 240) * 262144 + ((text:byte(i + 1) or 128) - 128) * 4096 + ((text:byte(i + 2) or 128) - 128) * 64 + ((text:byte(i + 3) or 128) - 128); n = 4
    end
    local isEmoji = (cp >= 0x1F000 and cp <= 0x1FAFF) or
      (cp >= 0x2600 and cp <= 0x27BF) or (cp >= 0x2300 and cp <= 0x23FF) or
      (cp >= 0x2B00 and cp <= 0x2BFF) or (cp >= 0x1F1E6 and cp <= 0x1F1FF) or
      cp == 0xFE0F or cp == 0xFE0E or cp == 0x200D or cp == 0x20E3 or
      (cp >= 0x1F3FB and cp <= 0x1F3FF)
    if not isEmoji then out[#out + 1] = text:sub(i, i + n - 1) end
    i = i + n
  end
  local cleaned = table.concat(out):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return cleaned
end

local function countEmojiCharacters(text)
  if not text or text == "" then return 0 end
  local count, i = 0, 1
  while i <= #text do
    local b1 = text:byte(i)
    local cp, n = b1, 1
    if b1 < 128 then
      cp, n = b1, 1
    elseif b1 < 224 and i + 1 <= #text then
      cp = (b1 - 192) * 64 + ((text:byte(i + 1) or 128) - 128); n = 2
    elseif b1 < 240 and i + 2 <= #text then
      cp = (b1 - 224) * 4096 + ((text:byte(i + 1) or 128) - 128) * 64 + ((text:byte(i + 2) or 128) - 128); n = 3
    elseif i + 3 <= #text then
      cp = (b1 - 240) * 262144 + ((text:byte(i + 1) or 128) - 128) * 4096 + ((text:byte(i + 2) or 128) - 128) * 64 + ((text:byte(i + 3) or 128) - 128); n = 4
    end
    if (cp >= 0x1F000 and cp <= 0x1FAFF) or (cp >= 0x2600 and cp <= 0x27BF) or
       (cp >= 0x2300 and cp <= 0x23FF) or (cp >= 0x2B00 and cp <= 0x2BFF) or
       (cp >= 0x1F1E6 and cp <= 0x1F1FF) then count = count + 1 end
    i = i + n
  end
  return count
end

local function countSentences(text)
  local count = 0
  for piece in tostring(text or ""):gmatch("[^%.!%?]+[%.!%?]*") do
    if piece:match("%S") then count = count + 1 end
  end
  return math.max(1, count)
end

local function addHighDensityFallback(text)
  local out = {}
  for seg in tostring(text or ""):gmatch("[^%.!%?]+[%.!%?]*") do
    local piece = seg:match("^%s*(.-)%s*$")
    if piece and piece ~= "" then
      local words = {}
      for word in piece:gmatch("%S+") do words[#words + 1] = word end
      if #words >= 6 then
        local middle = math.max(2, math.floor(#words / 2))
        words[middle] = words[middle] .. " 馃挮"
        piece = table.concat(words, " ")
      end
      local ending = pickMoodEmoji(piece) or "馃檪"
      piece = "鉁� " .. piece .. " " .. ending
      table.insert(out, piece)
    end
  end
  if #out == 0 then return text end
  return table.concat(out, " ")
end

local function applySelectedEmojiMode(text)
  if not text or text == "" then return text end
  local level = tostring(prefs.getString("emoji_level", "Punctuation Only"))
  local emojiOn = prefs.getBoolean("use_emoji", false)
  if not emojiOn or level == "None" or level == "Punctuation Only" or level == "Punctuation only" then
    return stripEmojiCharacters(text)
  end
  if level == "Low Emoji Typing" then level = "Low" end
  if level == "Medium Emoji" then level = "Medium" end
  if level == "High Emoji" then level = "High" end

  local existingEmojiCount = countEmojiCharacters(text)
  local sentenceCount = math.max(1, countSentences(text))
  local clauseCount = 0
  for _ in tostring(text):gmatch("[^,;%.!%?]+") do clauseCount = clauseCount + 1 end
  clauseCount = math.max(1, clauseCount)
  if level == "Medium" then
    -- Keep AI-selected semantic emojis when their density is moderate; normalize clutter.
    if existingEmojiCount > 0 and existingEmojiCount <= clauseCount then return text end
    return addClauseEmojiDensity(stripEmojiCharacters(text), "Medium")
  elseif level == "High" then
    -- High aims for 2 emojis per clause and 3 for long clauses; normalize under-dense AI output.
    if existingEmojiCount >= (clauseCount * 2) then return text end
    return addClauseEmojiDensity(stripEmojiCharacters(text), "High")
  elseif level == "Low" then
    -- Low remains sparse: preserve one or fewer emojis per sentence; normalize clutter.
    if existingEmojiCount > 0 and existingEmojiCount <= sentenceCount then return text end
    return addSentenceEndEmojis(stripEmojiCharacters(text), "Low")
  end
  return text
end

----------------------------------------------------------------
----------------------------------------------------------------
local defaultMarks = {".", "?", "!"}
local punctMarks = {
  hi = {"啷�", "?", "!"}, mr = {"啷�", "?", "!"}, ne = {"啷�", "?", "!"}, sa = {"啷�", "?", "!"}, bn = {"啷�", "?", "!"},
  zh = {"銆�", "锛�", "锛�"}, ja = {"銆�", "锛�", "锛�"},
  ar = {".", "責", "!"}, fa = {".", "責", "!"}, ur = {"蹟", "責", "!"}
}

local introEnglish = {
  "however", "therefore", "moreover", "furthermore", "meanwhile", "finally", "firstly", "secondly", "thirdly",
  "additionally", "actually", "basically", "honestly", "personally", "unfortunately", "fortunately", "luckily",
  "anyway", "besides", "hello", "hi", "hey", "yes", "okay", "ok", "sorry",
  "good morning", "good afternoon", "good evening", "good night", "by the way", "for example", "in fact",
  "of course", "in addition", "as a result", "on the other hand", "first of all", "after that", "at last",
  "vanakkam", "aanaal", "aana", "sari"
}
local introTamil = {
  "喈嗋喈距喁�", "喈嗋畷喈掂瘒", "喈庎喈掂瘒", "喈呧喈┼喈侧瘝", "喈囙喁佮喁嵿喈距喁佮喁�", "喈瘒喈侧瘉喈瘝", "喈瘉喈む喈苦喁�", "喈囙喈｀瘝喈熰喈掂喈距畷", "喈瘋喈┼瘝喈编喈掂喈距畷",
  "喈曕疅喁堗畾喈苦喈距畷", "喈夃喁嵿喁堗喈苦喁�", "喈ㄠ喈氞瘝喈氞喈喈�", "喈掂喈曕瘝喈曕喁�", "喈灌喁�", "喈灌喈瘝", "喈氞喈�", "喈嗋喈�", "喈嗋喁�",
  "喈曕瘉喈熰瘝 喈喈班瘝喈┼喈權瘝", "喈曕瘉喈熰瘝 喈堗喈苦喈苦畽喁�", "喈曕瘉喈熰瘝 喈ㄠ瘓喈熰瘝", "喈曕喈侧瘓 喈掂喈曕瘝喈曕喁�", "喈喈侧瘓 喈掂喈曕瘝喈曕喁�", "喈囙喈苦 喈囙喈掂瘉"
}

local conjEnglish = {"but", "although", "whereas", "otherwise", "aanaal", "aana"}
local conjTamil = {"喈嗋喈距喁�", "喈囙喁佮喁嵿喈距喁佮喁�"}

local leadFillers = {"hello", "hi", "hey", "okay", "ok", "yes", "so", "and", "but", "then", "well", "sorry", "please", "anyway", "actually", "excuse me", "vanakkam"}
local auxSet = {
  is = true, are = true, am = true, was = true, were = true, ["do"] = true, does = true, did = true,
  can = true, could = true, will = true, would = true, shall = true, should = true,
  have = true, has = true, had = true, may = true, might = true, must = true
}
local pronounSet = {
  i = true, you = true, he = true, she = true, it = true, we = true, they = true, there = true,
  this = true, that = true, anyone = true, everyone = true, someone = true
}
local romanTamilQuestion = {"enna", "yenna", "yen", "eppadi", "eppo", "eppodhu", "enge", "yenge", "yaaru", "yaar", "edhu", "evlo", "evvalavu"}
local otherQuestionWords = {
  "啶曕啶ぞ", "啶曕啶�", "啶曕が", "啶曕す啶距", "啶曕す啶距", "啶曕啶啶�", "啶曕啶膏", "啶曕た啶むえ啶�", "啶曕た啶むえ啷€", "啶曕た啶むえ啷�",
  "喟忇爱喟苦盁喟�", "喟庎皞喟︵眮喟曕眮", "喟庎安喟�", "喟庎蔼啾嵿蔼啾佮啊啾�", "喟庎皶啾嵿皶喟�", "喟庎暗喟班眮", "喟忇唉喟�",
  "嗖忇波喑�", "嗖簿嗖曕硢", "嗖忇矔喑�", "嗖灌硣嗖椸硢", "嗖簿嗖掂簿嗖�", "嗖庎膊喑嵿膊嗖�", "嗖簿嗖班硜", "嗖簿嗖掂硜嗖︵硜",
  "啻庎川嗟嵿搐嗟�", "啻庎川嗟嵿搐嗟佮磿嗟娻矗嗟嵿礋嗟�", "啻庎礄嗟嵿礄啻ㄠ祮", "啻庎椽嗟嵿椽嗟嬥稻", "啻庎吹啻苦礋嗟�", "啻嗋窗嗟�", "啻忇搐嗟�"
}
local tamilQuestionEndings = {"喁佮喈�", "喈距喈�", "喈赤", "喈"}
local tamilQuestionExcluded = {"喈愢喈�", "喈呧喁嵿喈�"}

local exclaimEnglish = {
  "wow", "congratulations", "congrats", "hurray", "hooray", "yay", "bravo", "awesome", "amazing", "excellent",
  "superb", "fantastic", "wonderful", "happy birthday", "happy diwali", "happy new year", "happy pongal",
  "welcome", "thank you", "thanks"
}
local exclaimEnglishStart = {
  "hello", "hi", "hey", "bye", "goodbye", "oh no", "stop", "help", "well done", "great", "super", "nice", "vanakkam",
  "good morning", "good afternoon", "good evening", "good night"
}
local exclaimTamil = {
  "喈掂喈脆瘝喈む瘝喈む瘉", "喈呧喁佮喁�", "喈氞瘋喈瘝喈喁�", "喈掂喈掂瘝", "喈ㄠ喁嵿喈�", "喈掂喈掂瘒喈编瘝", "喈呧疅喈熰", "喈愢喁�", "喈喈班喈熰瘝喈熰瘉", "喈嗋喈�", "喈む瘒喈權瘝喈曕瘝喈膏瘝"
}
local exclaimTamilStart = {
  "喈灌喁�", "喈灌喈瘝", "喈掂喈曕瘝喈曕喁�", "喈ㄠ喈编瘉喈む瘝喈む瘉", "喈夃喈掂", "喈掂瘑喈侧瘝喈�", "喈曕瘉喈熰瘝 喈喈班瘝喈┼喈權瘝", "喈曕瘉喈熰瘝 喈ㄠ瘓喈熰瘝", "喈曕喈侧瘓 喈掂喈曕瘝喈曕喁�", "喈囙喈苦 喈囙喈掂瘉"
}

local function phraseAt(lowerText, p, w)
  local n = #lowerText
  local e = p + #w - 1
  if e > n then return nil end
  if lowerText:sub(p, e) ~= w then return nil end
  if e == n then return e end
  if lowerText:sub(e + 1, e + 1):match("[%s%p]") then return e end
  return nil
end

local function sentenceStarts(text)
  local starts = {1}
  local init = 1
  while true do
    local s, e = text:find("[%.!%?]+%s+", init)
    if not s then break end
    table.insert(starts, e + 1)
    init = e + 1
  end
  return starts
end

local function countWords(sentence)
  local c = 0
  for _ in sentence:gmatch("%S+") do c = c + 1 end
  return c
end

local function addAutoCommas(text)
  local lowerText = text:lower()
  local n = #text
  local starts = sentenceStarts(text)
  local startSet = {}
  for _, p in ipairs(starts) do startSet[p] = true end
  local inserts = {}

  for _, p in ipairs(starts) do
    local bestE = nil
    for _, list in ipairs({introEnglish, introTamil}) do
      for _, w in ipairs(list) do
        local e = phraseAt(lowerText, p, w)
        if e and (not bestE or e > bestE) then bestE = e end
      end
    end
    if bestE and bestE < n then
      local after = text:sub(bestE + 2, bestE + 2)
      if text:sub(bestE + 1, bestE + 1) == " " and after ~= "" and not after:match("%p") then
        inserts[bestE] = true
      end
    end
  end

  local function addBefore(s)
    if not s or startSet[s] or s <= 2 then return end
    if text:sub(s - 1, s - 1) ~= " " then return end
    if text:sub(s - 2, s - 2):match("[%.,;:!%?]") then return end
    inserts[s - 2] = true
  end

  for _, w in ipairs(conjEnglish) do
    local init = 1
    local pat = "%f[%w]" .. escapeLuaPattern(w) .. "%f[%W]"
    while true do
      local s, e = lowerText:find(pat, init)
      if not s then break end
      addBefore(s)
      init = e + 1
    end
  end

  for _, w in ipairs(conjTamil) do
    local init = 1
    while true do
      local s, e = findTamilWord(lowerText, w, true, init)
      if not s then break end
      addBefore(s)
      init = e + 1
    end
  end

  local keys = {}
  for k, _ in pairs(inserts) do table.insert(keys, k) end
  table.sort(keys, function(a, b) return a > b end)
  for _, k in ipairs(keys) do
    text = text:sub(1, k) .. "," .. text:sub(k + 1)
  end
  return text
end

local function stripLeadFillers(lowerSentence)
  local body = lowerSentence
  for _ = 1, 2 do
    for _, w in ipairs(leadFillers) do
      local e = phraseAt(body, 1, w)
      if e then
        body = (body:sub(e + 1):gsub("^[%s%p]+", ""))
        break
      end
    end
  end
  return body
end

local function isQuestionSentence(sentence)
  if sentence:find("?", 1, true) then return true end
  local lowerS = sentence:lower()
  local body = stripLeadFillers(lowerS)

  local firstOnly = body:match("^(%a+)")
  if firstOnly then
    for _, q in ipairs(englishQuestionStarts) do
      if firstOnly == q then return true end
    end
  end

  local first, second = body:match("^(%a+)%s+(%a+)")
  if first and auxSet[first] and pronounSet[second] then return true end

  for _, q in ipairs(romanTamilQuestion) do
    if findEnglishWord(lowerS, q) then return true end
  end
  for _, q in ipairs(tamilQuestionWords) do
    if findTamilWord(lowerS, q, true) then return true end
  end
  for _, q in ipairs(otherQuestionWords) do
    if findTamilWord(lowerS, q, true) then return true end
  end

  local lastWord = lowerS:match("(%S+)%s*$")
  if lastWord then
    lastWord = (lastWord:gsub("[%.,!%?]+$", ""))
    local excluded = false
    for _, x in ipairs(tamilQuestionExcluded) do
      if lastWord == x then excluded = true end
    end
    if not excluded then
      for _, suf in ipairs(tamilQuestionEndings) do
        if #lastWord > #suf and lastWord:sub(-#suf) == suf then return true end
      end
    end
  end
  return false
end

local function isExclamationSentence(sentence)
  local lowerS = sentence:lower()
  local words = countWords(sentence)

  for _, w in ipairs(exclaimEnglishStart) do
    if phraseAt(lowerS, 1, w) then return true end
  end
  for _, w in ipairs(exclaimEnglish) do
    if phraseAt(lowerS, 1, w) then return true end
    if words <= 6 and findEnglishWord(lowerS, w) then return true end
  end
  for _, w in ipairs(exclaimTamilStart) do
    local s = findTamilWord(lowerS, w, false)
    if s == 1 then return true end
  end
  for _, w in ipairs(exclaimTamil) do
    local s = findTamilWord(lowerS, w, false)
    if s and (s == 1 or words <= 6) then return true end
  end
  return false
end

local function addEndMark(text, langCode)
  local trimmed = text:match("^%s*(.-)%s*$")
  if not trimmed or trimmed == "" then return text end

  if trimmed:sub(-1):match("[%.!%?]") then return trimmed end
  for _, m in ipairs({"啷�", "銆�", "锛�", "锛�", "責", "蹟"}) do
    if trimmed:sub(-#m) == m then return trimmed end
  end

  trimmed = (trimmed:gsub("[,;:]+$", ""))
  if trimmed == "" then return text end

  local starts = sentenceStarts(trimmed)
  local sentence = trimmed:sub(starts[#starts])

  local shortLang = tostring(langCode or ""):match("^(%a+)") or ""
  local marks = punctMarks[shortLang] or defaultMarks

  local mark = marks[1]
  if isQuestionSentence(sentence) then
    mark = marks[2]
  elseif isExclamationSentence(sentence) then
    mark = marks[3]
  end
  return trimmed .. mark
end

local function addAutoPunctuation(text, langCode)
  if not text or text == "" then return text end
  if not prefs.getBoolean("auto_punctuation", true) then return text end

  local t = (text:gsub("%s+", " "))
  t = t:match("^%s*(.-)%s*$")
  if not t or t == "" then return text end

  t = addAutoCommas(t)
  t = addEndMark(t, langCode)
  return t
end

----------------------------------------------------------------
----------------------------------------------------------------
-- Screen-reader announcement speaks ONLY the final text that was inserted.
-- Emoji characters stay unchanged in the edit box; known emoji are spoken by their readable names.
-- Do not announce the selected Emoji mode, ON/OFF state, or processing status after a successful typing action.
local function makeScreenReaderAnnouncement(text)
  local spoken = tostring(text or "")
  -- Replace emoji glyphs with just their spoken names. Do not say the word "emoji".
  local emojiNames = {
    ["馃檹"] = "folded hands", ["馃槉"] = "smiling face", ["馃檪"] = "slightly smiling face",
    ["馃槃"] = "grinning face", ["馃槀"] = "face with tears of joy", ["鉂わ笍"] = "red heart",
    ["馃槏"] = "smiling face with heart eyes", ["馃グ"] = "smiling face with hearts",
    ["馃槝"] = "face blowing a kiss", ["馃"] = "thinking face", ["馃憤"] = "thumbs up",
    ["馃憦"] = "clapping hands", ["馃帀"] = "party popper", ["鉁�"] = "sparkles",
    ["馃尮"] = "rose", ["馃尭"] = "cherry blossom", ["馃尀"] = "sun with face",
    ["鈽€锔�"] = "sun", ["馃導锔�"] = "rain cloud", ["馃寛"] = "rainbow",
    ["馃崕"] = "red apple", ["馃崐"] = "orange", ["馃崒"] = "banana",
    ["馃崜"] = "strawberry", ["馃崌"] = "grapes", ["馃崏"] = "watermelon",
    ["馃崼"] = "chocolate bar", ["馃巶"] = "birthday cake", ["馃"] = "juice box",
    ["馃摫"] = "mobile phone", ["馃捇"] = "laptop", ["馃殫"] = "car",
    ["鉂わ笍鈥嶐煍�"] = "heart on fire", ["馃挴"] = "hundred points", ["馃檹馃徎"] = "folded hands",
    ["鉂�"] = "question mark", ["鉁�"] = "check mark", ["鈿狅笍"] = "warning",
    ["馃敶"] = "red dot", ["馃數"] = "blue dot", ["馃煝"] = "green dot",
    ["馃"] = "handshake", ["馃挮"] = "dizzy", ["猸�"] = "star", ["馃専"] = "glowing star",
    ["鉂わ笍鈥嶐煩�"] = "mending heart", ["馃挅"] = "sparkling heart", ["馃拹"] = "bouquet",
    ["馃槩"] = "crying face", ["馃槶"] = "loudly crying face", ["馃槑"] = "smiling face with sunglasses",
    ["馃敟"] = "fire", ["馃挕"] = "light bulb", ["馃巵"] = "wrapped gift",
    ["馃嵃"] = "shortcake", ["鈽�"] = "hot beverage", ["馃コ"] = "partying face"
  }
  local keys = {}
  for emoji, _ in pairs(emojiNames) do keys[#keys + 1] = emoji end
  table.sort(keys, function(a, b) return #a > #b end)
  for _, emoji in ipairs(keys) do
    spoken = spoken:gsub(emoji, " " .. emojiNames[emoji] .. " ")
  end
  spoken = spoken:gsub("%s+", " ")
  return spoken
end

local function textHasEmoji(text)
  if not text then return false end
  if text:find("[\240-\244]") then return true end
  if text:find("\226[\152-\157]") then return true end
  return false
end

local function transferDecorations(srcText, srcLang, targetText)
  if not srcText or srcText == "" or not targetText or targetText == "" then return targetText end

  local normSrc = (srcText:gsub("%s+", " ")):match("^%s*(.-)%s*$")
  if not normSrc or normSrc == "" then return targetText end

  local O = {}
  for w in normSrc:gmatch("%S+") do table.insert(O, w) end
  if #O == 0 then return targetText end

  local annotated = addEmojisToNormalText(addAutoPunctuation(normSrc, srcLang))
  if annotated == normSrc then return targetText end

  local decor = {}
  for i = 1, #O do decor[i] = {suffix = "", emojis = ""} end

  local i = 1
  for tok in annotated:gmatch("%S+") do
    if i <= #O and tok:sub(1, #O[i]) == O[i] then
      decor[i].suffix = tok:sub(#O[i] + 1)
      i = i + 1
    else
      local last = math.max(1, i - 1)
      decor[last].emojis = decor[last].emojis .. " " .. tok
    end
  end

  local T = {}
  for w in targetText:gmatch("%S+") do table.insert(T, w) end
  if #T == 0 then return targetText end

  local extra = {}
  for oi = 1, #O do
    local d = decor[oi]
    if d.suffix ~= "" or d.emojis ~= "" then
      local tj = oi
      if #T ~= #O then
        tj = math.max(1, math.min(#T, math.floor(oi * #T / #O + 0.5)))
      end
      if d.suffix ~= "" and not T[tj]:sub(-1):match("[%.,!%?;:]") then
        T[tj] = T[tj] .. d.suffix
      end
      if d.emojis ~= "" then
        extra[tj] = (extra[tj] or "") .. d.emojis
      end
    end
  end

  local parts = {}
  for j = 1, #T do
    table.insert(parts, T[j] .. (extra[j] or ""))
  end
  return table.concat(parts, " ")
end

----------------------------------------------------------------
----------------------------------------------------------------
local SILENCE_END_MS = 2000
local SILENCE_POSSIBLE_MS = 1500

local function startSpeechRecognition(srcLang, tgtLang, isTranslateEnabled, isConvertEnglishEnabled, symbolChoice, targetEditNode)
  mainHandler.post(Runnable{
    run = function()
      cleanupRecognizer()

      local lastPartial = ""
      local handled = false

      local function processSpoken(spokenText)
        if handled then return end
        handled = true
        pcall(function() prefs.edit().putLong("last_dictation_execute_ms", 0).apply() end)
          Thread(Runnable{
            run = function()
              local processedText = spokenText
              local finalText = ""
              local usedAI = false
              local aiNote = ""

              local aiOn = prefs.getBoolean("ai_typing_enabled", false)
              local selectedTypingStyle = tostring(prefs.getString("emoji_level", "Punctuation Only"))
              local generatedCreativeText = false
              if aiOn then
                -- Query Mode is checked first for factual questions. Creative requests fall through to Messages/Quotes.
                if prefs.getBoolean("query_mode_enabled", false) then
                  local queryText, queryErr, wasQuery = selectedAnswerQuery(
                    spokenText, srcLang,
                    prefs.getBoolean("use_emoji", false), selectedTypingStyle)
                  if wasQuery and queryText and queryText ~= "" then
                    processedText = queryText
                    usedAI = true
                    generatedCreativeText = true
                  elseif queryErr and queryErr ~= "" then
                    aiNote = "Query Mode check unavailable. "
                  end
                end
                -- If it was not a factual query, let Messages/Quotes detect creative requests.
                if not generatedCreativeText and prefs.getBoolean("messages_quotes_enabled", false) then
                  local generatedText, genErr, wasCreativeRequest = selectedGenerateMessageOrQuote(
                    spokenText, srcLang,
                    prefs.getBoolean("use_emoji", false), selectedTypingStyle,
                    tostring(prefs.getString("messages_quotes_length", "Medium Message")))
                  if wasCreativeRequest and generatedText and generatedText ~= "" then
                    processedText = generatedText
                    usedAI = true
                    generatedCreativeText = true
                  elseif genErr and genErr ~= "" then
                    aiNote = aiNote .. "Messages and Quotes check unavailable. "
                  end
                end
                if not generatedCreativeText then
                  local aiText, aiErr = processWithSelectedAI(spokenText, srcLang, tgtLang, isTranslateEnabled, isConvertEnglishEnabled)
                  if aiText and aiText ~= "" then
                    processedText = aiText
                    usedAI = true
                  else
                    aiNote = aiNote .. "AI failed. " .. tostring(aiErr or "") .. " Normal typing used. "
                    doVibrate("error")
                  end
                end
              end

              if usedAI then
                if generatedCreativeText then
                  -- Generated message/quote is already complete; preserve its punctuation and requested language.
                  finalText = formatAIText(applySelectedEmojiMode(processedText))
                else
                -- AI ON: selected AI provider handles punctuation and context-aware emojis.
                local aiLang = srcLang
                local aiSrcShort = tostring(srcLang):match("^([%a]+)") or tostring(srcLang)
                if isTranslateEnabled then
                  aiLang = tgtLang
                elseif isConvertEnglishEnabled and aiSrcShort ~= "en" then
                  aiLang = "en"
                end
                local aiLevelNow = tostring(prefs.getString("emoji_level", "Medium Emoji"))
                if aiLevelNow ~= "None" then
                  -- Gemini is the semantic source for punctuation and emojis. Avoid local word-map emojis.
                  -- If the model omitted punctuation, local punctuation is a final fallback.
                  if aiLevelNow == "Punctuation Only" or not prefs.getBoolean("use_emoji", false) then
                    processedText = addAutoPunctuation(processedText, aiLang)
                  elseif not textHasEmoji(processedText) then
                    -- Do not append dictionary-based emojis; keep the API's context-aware result as-is.
                    processedText = addAutoPunctuation(processedText, aiLang)
                  end
                end
                finalText = formatAIText(applySelectedEmojiMode(processedText))
                end -- generatedCreativeText
              else
                if isTranslateEnabled then
                  local translated = translateOnline(spokenText, srcLang, tgtLang)
                  processedText = fixGrammarOnline(translated, tgtLang)
                elseif isConvertEnglishEnabled then
                  processedText = smartTransliterateUniversal(spokenText, srcLang)
                else
                  processedText = applyDictionaryWords(spokenText, srcLang, "normal")
                end
                -- Normal mode uses the same Google Gemini semantic punctuation/emoji processing when an API key is configured.
                -- None means no added punctuation/emojis. Without an API key, punctuation-only uses local punctuation; semantic emojis require Gemini.
                local srcShortLang = tostring(srcLang):match("^([%a]+)") or tostring(srcLang)
                local levelNow = tostring(prefs.getString("emoji_level", "Medium Emoji"))
                local emojiModeNow = prefs.getBoolean("use_emoji", false)
                local normalLang = srcLang
                if isTranslateEnabled then normalLang = tgtLang
                elseif isConvertEnglishEnabled and srcShortLang ~= "en" then normalLang = "en-US" end

                if not emojiModeNow then
                  -- Typing Mode OFF: normal typing adds no punctuation or emojis.
                else
                  local gKey = activeAIKey()
                  if gKey ~= "" then
                    local aiDecorated, decorateErr = processWithSelectedAI(processedText, normalLang, normalLang, false, false)
                    if aiDecorated and aiDecorated ~= "" then
                      processedText = aiDecorated
                    else
                      -- API failure: use local punctuation only; do not use a hard-coded semantic emoji dictionary.
                      if levelNow ~= "Punctuation Only" then aiNote = "Selected AI formatting unavailable; used local punctuation. " end
                      processedText = addAutoPunctuation(processedText, normalLang)
                    end
                  else
                    processedText = addAutoPunctuation(processedText, normalLang)
                    if levelNow ~= "Punctuation Only" and emojiModeNow then
                      aiNote = "Set the selected AI provider API key for context-aware emojis. "
                    end
                  end
                end
                finalText = formatAndAppendSymbol(applySelectedEmojiMode(processedText), "Space")
              end

              mainHandler.post(Runnable{
                run = function()
                  local currentEdit = service.getEditText() or targetEditNode
                  if currentEdit then
                    service.insertText(currentEdit, finalText)
                    -- Speak only the inserted final text (with readable names for known emojis).
                    -- Do not append mode names, ON/OFF status, or AI-processing commentary.
                    service.asyncSpeak(makeScreenReaderAnnouncement(finalText))
                  else
                    service.asyncSpeak("Speech recognized, but no editable text field was found.")
                  end
                  cleanupRecognizer()
                end
              })
            end
          }).start()
      end

      _G.activeSpeechRecognizer = SpeechRecognizer.createSpeechRecognizer(service)
      local recordIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
      recordIntent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
      recordIntent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, srcLang)
      pcall(function() recordIntent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true) end)
      pcall(function()
        local JLong = luajava.bindClass("java.lang.Long")
        recordIntent.putExtra("android.speech.extra.SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS", JLong.valueOf(SILENCE_END_MS))
        recordIntent.putExtra("android.speech.extra.SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS", JLong.valueOf(SILENCE_POSSIBLE_MS))
      end)

      _G.activeSpeechRecognizer.setRecognitionListener(RecognitionListener{
        onReadyForSpeech = function(params)
          _G.isRDSListening = true
          doVibrate("start")
          pcall(warmUpSelectedAI)
        end,

        onBeginningOfSpeech = function()
          _G.isRDSListening = true
        end,

        onRmsChanged = function(rmsdB) end,
        onBufferReceived = function(buffer) end,

        onEndOfSpeech = function()
          _G.isRDSListening = false
        end,

        onResults = function(results)
          _G.isRDSListening = false
          local spokenList = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
          
          if not spokenList or spokenList.isEmpty() then
            if lastPartial ~= "" then
              doVibrate("success")
              processSpoken(lastPartial)
              return
            end
            doVibrate("error")
            cleanupRecognizer()
            return
          end

          doVibrate("success")
          local spokenText = tostring(spokenList.get(0))

          processSpoken(spokenText)
        end,

        onError = function(err)
          if lastPartial ~= "" and not handled then
            _G.isRDSListening = false
            doVibrate("success")
            processSpoken(lastPartial)
            return
          end
          doVibrate("error")
          cleanupRecognizer()
          service.asyncSpeak("Voice stopped!")
        end,

        onPartialResults = function(partialResults)
          pcall(function()
            local pl = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            if pl and not pl.isEmpty() then
              local ptxt = tostring(pl.get(0))
              if ptxt ~= "" then lastPartial = ptxt end
            end
          end)
        end,
        onEvent = function(eventType, params) end
      })

      _G.activeSpeechRecognizer.startListening(recordIntent)
    end
  })
end

----------------------------------------------------------------
----------------------------------------------------------------
local function swapLanguagesOnly()
  local srcCode = prefs.getString("source_lang_code", "ta-IN")
  local srcName = prefs.getString("source_lang_name", "Tamil")
  local tgtCode = prefs.getString("target_lang_code", "en-US")
  local tgtName = prefs.getString("target_lang_name", "English")

  local editor = prefs.edit()
  editor.putString("source_lang_code", tgtCode)
  editor.putString("source_lang_name", tgtName)
  editor.putString("target_lang_code", srcCode)
  editor.putString("target_lang_name", srcName)
  pcall(function() editor.putLong("last_dictation_execute_ms", 0) end)
  editor.apply()

  doVibrate("success")
  service.asyncSpeak("Voice dictation language is now " .. tgtName .. ". Translation target is now " .. srcName)
end

----------------------------------------------------------------
-- 10. Navigation button shortcuts
-- Home = AI/Normal toggle; Back = cycle typing pipeline; Overview = cycle punctuation/emoji level.
----------------------------------------------------------------
local function toggleAIMode()
  local newVal = not prefs.getBoolean("ai_typing_enabled", false)
  local editor = prefs.edit()
  editor.putBoolean("ai_typing_enabled", newVal)
  editor.putString("navigation_pipeline_mode", "Typing Mode")
  -- AI-only modes cannot remain active when AI is switched off.
  if not newVal then
    editor.putBoolean("messages_quotes_enabled", false)
    editor.putBoolean("query_mode_enabled", false)
  end
  editor.apply()

  doVibrate("success")
  if newVal then
    if activeAIKey() == "" then
      service.asyncSpeak("Normal mode off. AI mode on. Please set the selected AI provider API key in AI Settings.")
    else
      service.asyncSpeak("Normal mode off. AI mode on.")
    end
  else
    service.asyncSpeak("AI mode off. Normal mode on. Messages and Quotes and Query Mode disabled.")
  end
end

local function cycleTypingPipelineMode()
  local aiOn = prefs.getBoolean("ai_typing_enabled", false)
  local translateOn = prefs.getBoolean("translate_enabled", false)
  local convertOn = prefs.getBoolean("convert_english_enabled", false)
  local messagesOn = prefs.getBoolean("messages_quotes_enabled", false)
  local queryOn = prefs.getBoolean("query_mode_enabled", false)

  local modes
  if aiOn then
    modes = {"Typing Mode", "Translation Mode", "English Converter", "Message and Quotes", "Query Mode"}
  else
    modes = {"Typing Mode", "Translation Mode", "English Converter"}
  end

  -- Keep an explicit cycle cursor. This avoids the old default convert_english_enabled=true
  -- making the very first Back press incorrectly start at English Converter.
  local current = tostring(prefs.getString("navigation_pipeline_mode", "Typing Mode"))
  local validCurrent = false
  if aiOn then
    for _, modeName in ipairs({"Typing Mode", "Translation Mode", "English Converter", "Message and Quotes", "Query Mode"}) do
      if current == modeName then validCurrent = true break end
    end
  else
    for _, modeName in ipairs({"Typing Mode", "Translation Mode", "English Converter"}) do
      if current == modeName then validCurrent = true break end
    end
  end
  if not validCurrent then current = "Typing Mode" end

  local currentIndex = 1
  for i, modeName in ipairs(modes) do
    if modeName == current then currentIndex = i break end
  end
  local nextIndex = (currentIndex % #modes) + 1
  local nextMode = modes[nextIndex]

  local editor = prefs.edit()
  editor.putBoolean("translate_enabled", nextMode == "Translation Mode")
  editor.putBoolean("convert_english_enabled", nextMode == "English Converter")
  editor.putBoolean("messages_quotes_enabled", aiOn and nextMode == "Message and Quotes")
  editor.putBoolean("query_mode_enabled", aiOn and nextMode == "Query Mode")
  editor.putString("navigation_pipeline_mode", nextMode)
  editor.apply()

  doVibrate("success")
  service.asyncSpeak(nextMode)
end

local function cycleEmojiPunctuationLevel()
  local level = tostring(prefs.getString("emoji_level", "Punctuation Only"))
  local levelAliases = {
    ["Low"] = "Low Emoji Typing",
    ["Medium"] = "Medium Emoji",
    ["High"] = "High Emoji",
    ["Punctuation only"] = "Punctuation Only"
  }
  level = levelAliases[level] or level

  local levels = {"Punctuation Only", "Low Emoji Typing", "Medium Emoji", "High Emoji"}
  local currentIndex = 1
  for i, levelName in ipairs(levels) do
    if levelName == level then currentIndex = i break end
  end
  local nextLevel = levels[(currentIndex % #levels) + 1]
  local editor = prefs.edit()
  editor.putString("emoji_level", nextLevel)
  -- This shortcut cycles active formatting levels, so enable Typing Mode as well.
  editor.putBoolean("use_emoji", true)
  editor.apply()

  doVibrate("success")
  service.asyncSpeak(nextLevel)
end

----------------------------------------------------------------
----------------------------------------------------------------
local editNode = service.getEditText()

-- Robust navigation focus detection. Home uses service.getText(node), which is retained.
-- Back/Overview labels differ by Samsung model, Android version, screen reader, and language.
local focusCandidates = {}
local function addFocusCandidate(value)
  if value == nil then return end
  local valueText = ""
  pcall(function() valueText = tostring(value) end)
  valueText = valueText:gsub("^%s+", ""):gsub("%s+$", "")
  if valueText ~= "" and valueText ~= "nil" and valueText ~= "null" then
    valueText = valueText:lower():gsub("%s+", " ")
    table.insert(focusCandidates, valueText)
  end
end

-- Same primary path as the working Home shortcut.
pcall(function() addFocusCandidate(service.getText(node)) end)
-- Node metadata commonly used by accessibility services.
pcall(function() addFocusCandidate(service.getContentDescription(node)) end)
pcall(function() addFocusCandidate(node.getText()) end)
pcall(function() addFocusCandidate(node.getContentDescription()) end)
pcall(function() addFocusCandidate(node.getViewIdResourceName()) end)
pcall(function() addFocusCandidate(node.getClassName()) end)
pcall(function() addFocusCandidate(node.getPaneTitle()) end)
pcall(function() addFocusCandidate(node.getTooltipText()) end)

-- Walk up from the supplied focused node. Navigation nodes sometimes have a useful label on a parent.
pcall(function()
  local current = node
  for depth = 1, 5 do
    if current == nil then break end
    pcall(function() addFocusCandidate(current.getText()) end)
    pcall(function() addFocusCandidate(current.getContentDescription()) end)
    pcall(function() addFocusCandidate(current.getViewIdResourceName()) end)
    pcall(function() addFocusCandidate(current.getClassName()) end)
    local parent = nil
    pcall(function() parent = current.getParent() end)
    current = parent
  end
end)

-- If the accessibility service exposes a root, inspect only focused nodes and nearby labels.
-- The system navigation bar may be a separate window and may not be visible in this tree.
pcall(function()
  local root = service.getRootInActiveWindow()
  if root then
    local visited = 0
    local function scan(current, depth)
      if current == nil or depth > 14 or visited > 500 then return end
      visited = visited + 1
      local focused = false
      pcall(function() if current.isAccessibilityFocused() then focused = true end end)
      pcall(function() if current.isFocused() then focused = true end end)
      if focused then
        pcall(function() addFocusCandidate(current.getText()) end)
        pcall(function() addFocusCandidate(current.getContentDescription()) end)
        pcall(function() addFocusCandidate(current.getViewIdResourceName()) end)
        pcall(function() addFocusCandidate(current.getClassName()) end)
        -- Include siblings of a focused node: some services expose the label on a sibling.
        local parent = nil
        pcall(function() parent = current.getParent() end)
        if parent then
          local siblings = 0
          pcall(function() siblings = tonumber(parent.getChildCount()) or 0 end)
          for si = 0, siblings - 1 do
            local sibling = nil
            pcall(function() sibling = parent.getChild(si) end)
            if sibling then
              pcall(function() addFocusCandidate(sibling.getText()) end)
              pcall(function() addFocusCandidate(sibling.getContentDescription()) end)
              pcall(function() addFocusCandidate(sibling.getViewIdResourceName()) end)
            end
          end
        end
      end
      local count = 0
      pcall(function() count = tonumber(current.getChildCount()) or 0 end)
      for ci = 0, count - 1 do
        if visited > 500 then break end
        local child = nil
        pcall(function() child = current.getChild(ci) end)
        if child then scan(child, depth + 1) end
      end
    end
    scan(root, 0)
  end
end)

local function labelContainsAny(label, terms)
  for _, term in ipairs(terms) do
    if label:find(term, 1, true) then return true end
  end
  return false
end
local function anyFocusMatches(exactLabels, fragments)
  for _, label in ipairs(focusCandidates) do
    for _, expected in ipairs(exactLabels) do
      if label == expected then return true end
    end
    if labelContainsAny(label, fragments) then return true end
  end
  return false
end

local isHomeFocused = anyFocusMatches(
  {"home", "home button", "home navigation", "喈瘉喈曕喁嵿喁�", "嗖硜嗖栢勃喑佮矡", "啶灌啶�"},
  {"home button", "home navigation", "喈瘉喈曕喁嵿喁� 喈瘖喈む瘝喈む喈┼瘝", "嗖硜嗖栢勃喑佮矡 嗖矡嗖ㄠ硩"})
local isBackFocused = anyFocusMatches(
  {"back", "back button", "back navigation", "navigate back", "navigate up", "go back", "喈喈┼瘝", "喈喈┼瘝喈┼喈侧瘝", "嗖灌部嗖傕拨喑�", "啶掂ぞ啶じ", "啶掂ぞ啶じ 啶溹ぞ啶忇"},
  {"back button", "back navigation", "navigate back", "navigate up", "go back", "back key", "btn_back", "navigation_bar_back", "喈喈┼瘝 喈瘖喈む瘝喈む喈┼瘝", "喈喈┼瘝喈┼喈侧瘝 喈瘖喈む瘝喈む喈┼瘝", "嗖灌部嗖傕拨喑� 嗖矡嗖ㄠ硩", "啶掂ぞ啶じ 啶啶�"})
local isOverviewFocused = anyFocusMatches(
  {"overview", "overview button", "overview navigation", "recent apps", "recent apps button", "recent applications", "recents", "recents button", "task switcher", "switch apps", "喈氞喁€喈喁嵿喈苦 喈喈┼瘝喈喈熰瘉喈曕喁�", "喈瘒喈侧瘚喈熰瘝喈熰喁�", "嗖囙菠喑嵿菠喑€嗖氞部嗖� 嗖呧勃喑嵿膊嗖苦矔喑囙捕嗖ㄠ硩鈥屶矖嗖赤硜", "嗖囙菠喑嵿菠喑€嗖氞部嗖� 嗖呧勃喑嵿膊嗖苦矔喑囙捕嗖ㄠ硩嗖椸渤喑�", "啶灌ぞ啶� 啶曕 啶愢お啷嵿じ"},
  {"overview button", "overview navigation", "recent apps", "recent applications", "recents button", "task switcher", "switch apps", "navigation_bar_recent", "recent_apps", "btn_recent", "喈氞喁€喈喁嵿喈苦 喈喈┼瘝喈喈熰瘉喈曕喁�", "喈瘒喈侧瘚喈熰瘝喈熰喁�", "嗖囙菠喑嵿菠喑€嗖氞部嗖� 嗖呧勃喑嵿膊嗖苦矔喑囙捕嗖ㄠ硩", "啶灌ぞ啶� 啶曕 啶愢お啷嵿じ"})

if isHomeFocused then
  -- Home execute: toggle AI mode.
  toggleAIMode()
elseif isBackFocused then
  -- Back execute: cycle available typing modes. AI OFF has only three modes.
  cycleTypingPipelineMode()
elseif isOverviewFocused then
  -- Overview execute: Punctuation Only -> Low -> Medium -> High -> repeat.
  cycleEmojiPunctuationLevel()
elseif _G.isRDSListening then
  -- Execute again while listening: stop recognition and swap source/target languages.
  cleanupRecognizer()
  swapLanguagesOnly()
else
  if not editNode then
    openSettingsDialog()
  else
    local nowMs = tonumber(System.currentTimeMillis()) or 0
    local lastMs = 0
    pcall(function() lastMs = tonumber(prefs.getLong("last_dictation_execute_ms", 0)) or 0 end)
    local quickSecondExecute = lastMs > 0 and nowMs >= lastMs and (nowMs - lastMs) <= 1800

    if quickSecondExecute then
      -- A second execute may arrive before onReadyForSpeech; still swap reliably.
      cleanupRecognizer()
      swapLanguagesOnly()
    else
      pcall(function() prefs.edit().putLong("last_dictation_execute_ms", nowMs).apply() end)
      local srcLang = prefs.getString("source_lang_code", "ta-IN")
      local tgtLang = prefs.getString("target_lang_code", "en-US")
      local isTranslateEnabled = prefs.getBoolean("translate_enabled", false)
      local isConvertEnglishEnabled = prefs.getBoolean("convert_english_enabled", true)
      local symbolChoice = "Space"
      startSpeechRecognition(srcLang, tgtLang, isTranslateEnabled, isConvertEnglishEnabled, symbolChoice, editNode)
    end
  end
end
