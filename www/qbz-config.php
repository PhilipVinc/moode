<?php
/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2014 The moOde audio player project / Tim Curtis
*/

require_once __DIR__ . '/inc/common.php';
require_once __DIR__ . '/inc/session.php';
require_once __DIR__ . '/inc/sql.php';

$dbh = sqlConnect();
phpSession('open');

if (isset($_POST['save']) && $_POST['save'] == '1') {
	foreach ($_POST['config'] as $key => $value) {
		chkValue($key, $value);
		sqlUpdate('cfg_qobuz', $dbh, $key, $value);
	}
	$notify = $_SESSION['qobuzsvc'] == '1' ?
		array('title' => NOTIFY_TITLE_INFO, 'msg' => NAME_QOBUZ . NOTIFY_MSG_SVC_RESTARTED) :
		array('title' => '', 'msg' => '');
	submitJob('qobuzsvc', '', $notify['title'], $notify['msg']);
}
if (isset($_POST['qobuz_login']) && $_POST['qobuz_login'] == '1') {
	submitJob('qobuz_login', '', NOTIFY_TITLE_INFO, 'Login started, refresh this screen to view the login link');
}
if (isset($_POST['qobuz_logout']) && $_POST['qobuz_logout'] == '1') {
	submitJob('qobuz_logout', '', NOTIFY_TITLE_INFO, 'Logged out from Qobuz');
}

phpSession('close');

$result = sqlRead('cfg_qobuz', $dbh);
$cfgQobuz = array();

foreach ($result as $row) {
	$cfgQobuz[$row['param']] = $row['value'];
}

$_select['quality'] .= "<option value=\"mp3\" " . (($cfgQobuz['quality'] == 'mp3') ? "selected" : "") . ">MP3 320 kbps</option>\n";
$_select['quality'] .= "<option value=\"cd\" " . (($cfgQobuz['quality'] == 'cd') ? "selected" : "") . ">CD 16 bit / 44.1 kHz</option>\n";
$_select['quality'] .= "<option value=\"hires\" " . (($cfgQobuz['quality'] == 'hires') ? "selected" : "") . ">Hi-Res 24 bit / 96 kHz</option>\n";
$_select['quality'] .= "<option value=\"hires_plus\" " . (($cfgQobuz['quality'] == 'hires_plus') ? "selected" : "") . ">Hi-Res 24 bit / 192 kHz (Default)</option>\n";
$_select['gapless'] .= "<option value=\"Yes\" " . (($cfgQobuz['gapless'] == 'Yes') ? "selected" : "") . ">Yes (Default)</option>\n";
$_select['gapless'] .= "<option value=\"No\" "  . (($cfgQobuz['gapless'] == 'No')  ? "selected" : "") . ">No</option>\n";
$_select['normalize_volume'] .= "<option value=\"Yes\" " . (($cfgQobuz['normalize_volume'] == 'Yes') ? "selected" : "") . ">Yes</option>\n";
$_select['normalize_volume'] .= "<option value=\"No\" "  . (($cfgQobuz['normalize_volume'] == 'No')  ? "selected" : "") . ">No (Default)</option>\n";

// Account: login status is read from the qbzd control API (only available when the service is on)
$_qobuz_login_hide = 'hide';
$_qobuz_logout_hide = 'hide';
$_qobuz_login_url_msg = '';
if ($_SESSION['qobuzsvc'] == '1') {
	$result = sysCmd('curl -s --max-time 2 http://127.0.0.1:8182/api/status');
	$status = json_decode(implode('', $result), true);
	if (isset($status['auth']['state']) && $status['auth']['state'] != 'needs_auth') {
		$_qobuz_logout_hide = '';
		$_qobuz_account_status = 'Logged in' .
			(empty($status['auth']['subscription']) ? '' : ' (' . $status['auth']['subscription'] . ')');
	} else {
		$_qobuz_login_hide = '';
		// With the pairing surface up, a login is optional: the Qobuz app hands
		// the player its own session tokens when someone casts to it.
		$pairingOn = isset($status['qconnect']['pairing']) && $status['qconnect']['pairing'] === true;
		$_qobuz_account_status = $pairingOn ?
			'Not logged in (optional: any Qobuz app on this network can cast to this player)' :
			'Not logged in';
		// A login in progress prints its URL to the login log
		$loginLog = file_exists(QOBUZ_LOGIN_LOG) ? file_get_contents(QOBUZ_LOGIN_LOG) : '';
		if (preg_match('#https?://\S+#', $loginLog, $matches) === 1) {
			$_qobuz_login_url_msg = '<span class="config-help-static">' .
				'<a class="target-blank-link" href="' . $matches[0] . '" target="_blank">' . $matches[0] . '</a><br>' .
				'Open this link in your browser to complete the Qobuz login, then refresh this screen.</span>';
		}
	}
} else {
	$_qobuz_account_status = 'Turn the renderer on in Renderer Config to log in.';
}

waitWorker('qbz_config');

$tpl = "qbz-config.html";
$section = basename(__FILE__, '.php');
storeBackLink($section, $tpl);

include('header.php');
eval("echoTemplate(\"" . getTemplate("templates/$tpl") . "\");");
include('footer.php');
