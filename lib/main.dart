import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_frame_app/rx/photo.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/camera_settings.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  // stream subscription to pull application data back from camera
  StreamSubscription<Uint8List>? _photoStream;

  // the list of images to show in the scolling list view
  final List<Image> _imageList = [];
  final List<Uint8List> _jpegBytes = [];
  // the size x size list of individual images that will be composited to the larger image
  final List<img.Image> _cellImageList = [];
  final Stopwatch _stopwatch = Stopwatch();

  // camera settings
  final List<double> _qualityValues = [10, 25, 50, 100];

  MainAppState() {
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
  }

  @override
  Future<void> run() async {
    setState(() {
      currentState = ApplicationState.running;
    });

    try {
      const qualityIndex = 1;
      const isAutoExposure = false;
      // number of cells on each side of the square grid
      const size = 8;
      _cellImageList.clear();

      // loop over analog gain in SIZE rows
      for (var row = 0; row < size; row++) {
        int gainVal = row * 248~/(size-1);

        // horizontal log(shutter) values
        for (var col = 0; col < size; col++) {
          double minLog = log(4);
          double maxLog = log(16383);
          double logShutterVal = minLog + col * (maxLog-minLog) / (size - 1);
          int shutterVal = exp(logShutterVal).clamp(4, 16343).toInt();

          _log.info('Requesting Photo: shutter=$shutterVal, gain=$gainVal');

          try {
            // send the lua command to request a photo from the Frame
            _stopwatch.reset();
            _stopwatch.start();

            // Send the respective settings for an auto or a manual photo
            // ignore: dead_code
            if (isAutoExposure) {
              await frame!.sendMessage(TxCameraSettings(
                msgCode: 0x0d,
                qualityIndex: qualityIndex,
                autoExpGainTimes: 5, // val >= 0; number of times auto exposure and gain algorithm will be run every _autoExpInterval ms
                autoExpInterval: 100,  // 0<= val <= 255; sleep time between runs of the autoexposure algorithm
                meteringIndex: 2,  // ['SPOT', 'CENTER_WEIGHTED', 'AVERAGE'];
                exposure: 0.18, // 0.0 <= val <= 1.0
                exposureSpeed: 0.5, // 0.0 <= val <= 1.0
                shutterLimit: 16383,  // 4 < val < 16383
                analogGainLimit: 248,  // 0 <= val <= 248
                whiteBalanceSpeed: 0.5,  // 0.0 <= val <= 1.0
              ));
            }
            else {
              await frame!.sendMessage(TxCameraSettings(
                msgCode: 0x0d,
                qualityIndex: qualityIndex,
                autoExpGainTimes: 0,
                manualShutter: shutterVal,  // 4 < val < 16383
                manualAnalogGain: gainVal,  // 0 <= val <= 248
                manualRedGain: 128,  // 0 <= val <= 1023
                manualGreenGain: 128,  // 0 <= val <= 1023
                manualBlueGain: 128,  // 0 <= val <= 1023
              ));
            }

            // wait and receive the photo synchronously
            Uint8List imageData = await RxPhoto(qualityLevel: _qualityValues[qualityIndex].toInt()).attach(frame!.dataResponse).single;
            // received a whole-image Uint8List with jpeg header and footer included
            _stopwatch.stop();

            // unsubscribe from the image stream now (to also release the underlying data stream subscription)
            _photoStream?.cancel();

            try {
              img.Image im = img.decodeImage(imageData)!;
              // rotate the image 90 degrees counterclockwise since the Frame camera is rotated 90 clockwise
              img.Image rotatedImage = img.copyRotate(im, angle: 270);

              _log.fine('Image file size in bytes: ${imageData.length}, elapsedMs: ${_stopwatch.elapsedMilliseconds}');

              setState(() {
                _cellImageList.add(rotatedImage);
              });
            } catch (e) {
              _log.severe('Error converting bytes to image: $e');
              // add a dummy image if there was an issue
              _cellImageList.add(img.Image(width: 512, height: 512));
            }
          } catch (e) {
            _log.severe('Error reading image data response: $e');
            // unsubscribe from the image stream now (to also release the underlying data stream subscription)
            _photoStream?.cancel();
          }
        } // inner for loop - single row
      } // for loop

      // now make a composite image
      Uint8List compositeJpgBytes = img.encodeJpg(combineImagesIntoGrid(_cellImageList, size, _cellImageList[0].width));
      _imageList.insert(0, Image.memory(compositeJpgBytes));
      _jpegBytes.insert(0, compositeJpgBytes);

      setState(() {
        currentState = ApplicationState.ready;
      });
    }
    catch (e) {
      _log.severe('Error executing application: $e');
      setState(() {
        currentState = ApplicationState.ready;
      });
    }
  }

  /// cancel the current photo
  @override
  Future<void> cancel() async {
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  img.Image combineImagesIntoGrid(List<img.Image> images, int gridSize, int cellSize) {
    if (images.length != gridSize * gridSize) {
      throw ArgumentError('The list of images must be of length $gridSize * $gridSize');
    }

    // Set the width and height of each single image
    final int imageWidth = cellSize;
    final int imageHeight = cellSize;

    // Create a new image to hold the NxN grid
    final int gridWidth = gridSize * imageWidth;
    final int gridHeight = gridSize * imageHeight;
    final img.Image gridImage = img.Image(width: gridWidth, height: gridHeight);

    // Draw each image onto the grid image at the correct position
    for (int i = 0; i < gridSize; i++) {
      for (int j = 0; j < gridSize; j++) {
        final img.Image image = images[i * gridSize + j];
        img.compositeImage(gridImage, image, dstX: j * imageWidth, dstY: i * imageHeight);
      }
    }

    return gridImage;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camera Parameter Sweep',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Camera Parameter Sweep'),
          actions: [getBatteryWidget()]
        ),
        body: Flex(
          direction: Axis.vertical,
          children: [
            Expanded(
              // scrollable list view for multiple photos
              child: ListView.separated(
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        GestureDetector(
                          onTap: () => _shareImage(_imageList[index], _jpegBytes[index]),
                          child: _imageList[index]
                        ),
                      ],
                    )
                  );
                },
                separatorBuilder: (context, index) => const Divider(height: 30),
                itemCount: _imageList.length,
              ),
            ),
          ]
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.camera_alt), const Icon(Icons.cancel)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }

  void _shareImage(Image image, Uint8List jpegBytes) async {
    try {
    // Share the image bytes as a JPEG file
    await Share.shareXFiles(
      [XFile.fromData(jpegBytes, mimeType: 'image/jpeg', name: 'image.jpg')],
      text: 'Frame camera image',
    );
    }
    catch (e) {
      _log.severe('Error preparing image for sharing: $e');
    }
  }
}
