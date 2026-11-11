import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:budget/colors.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/reviewInboxPage.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/smsReview/reviewManager.dart';
import 'package:budget/struct/smsReview/smsAutoRefreshService.dart';
import 'package:budget/widgets/textWidgets.dart';

class HomeSmsSyncButton extends StatelessWidget {
  const HomeSmsSyncButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (getPlatform(ignoreEmulation: true) != PlatformOS.isAndroid) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<bool>(
      valueListenable: SmsAutoRefreshService.instance.isScanning,
      builder: (context, isScanning, _) {
        return ValueListenableBuilder<int>(
          valueListenable: ReviewManager.instance.pendingCountNotifier,
          builder: (context, pendingCount, _) {
            final iconWidget = isScanning
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  )
                : Icon(
                    appStateSettings["outlinedIcons"]
                        ? Icons.sync_outlined
                        : Icons.sync_rounded,
                  );

            return Tooltip(
              message: isScanning
                  ? "Syncing SMS Inbox..."
                  : (pendingCount > 0
                      ? "$pendingCount SMS transactions to review (Tap to sync, long-press to open inbox)"
                      : "Sync SMS Inbox (Tap to check for new bank transactions)"),
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  IconButton(
                    padding: const EdgeInsetsDirectional.all(15),
                    onPressed: isScanning
                        ? null
                        : () async {
                            HapticFeedback.lightImpact();
                            await SmsAutoRefreshService.instance
                                .scanNow(showToast: true);
                          },
                    icon: iconWidget,
                  ),
                  if (pendingCount > 0)
                    PositionedDirectional(
                      top: 7,
                      end: 7,
                      child: GestureDetector(
                        onTap: () {
                          pushRoute(context, const ReviewInboxPage());
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Theme.of(context).colorScheme.surface,
                              width: 1.5,
                            ),
                          ),
                          child: TextFont(
                            text: pendingCount > 99 ? "99+" : "$pendingCount",
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            textColor:
                                Theme.of(context).colorScheme.onPrimary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// A compact dismissible alert on the Home Screen showing when new SMS transactions are waiting for review
class HomePendingTransactionsBanner extends StatelessWidget {
  const HomePendingTransactionsBanner({super.key});

  @override
  Widget build(BuildContext context) {
    if (getPlatform(ignoreEmulation: true) != PlatformOS.isAndroid) {
      return const SizedBox.shrink();
    }

    return ValueListenableBuilder<int>(
      valueListenable: ReviewManager.instance.pendingCountNotifier,
      builder: (context, pendingCount, _) {
        if (pendingCount <= 0) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 4.0),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              pushRoute(context, const ReviewInboxPage());
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withOpacity(0.35),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color:
                      Theme.of(context).colorScheme.primary.withOpacity(0.3),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.mark_email_unread_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFont(
                          text: pendingCount == 1
                              ? "1 SMS Transaction Ready to Review"
                              : "$pendingCount SMS Transactions Ready to Review",
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          textColor: Theme.of(context).colorScheme.onSurface,
                        ),
                        TextFont(
                          text: "Tap to review & log into your accounts",
                          fontSize: 11,
                          textColor: getColor(context, "textLight"),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
