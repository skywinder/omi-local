import 'package:flutter/material.dart';

import 'build_info.g.dart';
import 'cv1_transport.dart';
import 'settings_labels.dart';

class NextAboutPage extends StatelessWidget {
  const NextAboutPage({super.key, this.cv1});

  final Cv1Connection? cv1;

  @override
  Widget build(BuildContext context) {
    String label(String key) => pairedSettingsLabel(context, key);
    return Scaffold(
      appBar: AppBar(title: Text(label('nextAbout'))),
      body: ListView(
        children: [
          ListTile(title: Text(label('nextAppVersion')), subtitle: const SelectableText(nextAppVersion)),
          ListTile(title: Text(label('nextBuildNumber')), subtitle: const SelectableText(nextBuildNumber)),
          ListTile(
            title: Text(label('nextBuildCommit')),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SelectableText(nextBuildCommit),
                if (nextBuildHasLocalChanges) Text(label('nextBuildLocalChanges')),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: Listenable.merge([cv1]),
            builder: (context, _) {
              final firmware = cv1?.phase == Cv1LinkPhase.ready ? cv1?.diagnostics?.firmware : null;
              return ListTile(
                title: Text(label('nextCv1Firmware')),
                subtitle: Text(firmware ?? label('nextCv1FirmwareUnavailable')),
              );
            },
          ),
        ],
      ),
    );
  }
}
