/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

package samza.examples.wikipedia.task;

import java.util.Map;
import java.util.Random;
import org.apache.samza.context.Context;
import org.apache.samza.context.TaskContext;
import org.apache.samza.storage.kv.KeyValueStore;
import org.apache.samza.system.IncomingMessageEnvelope;
import org.apache.samza.system.OutgoingMessageEnvelope;
import org.apache.samza.system.SystemStream;
import org.apache.samza.task.InitableTask;
import org.apache.samza.task.MessageCollector;
import org.apache.samza.task.StreamTask;
import org.apache.samza.task.TaskCoordinator;
import samza.examples.wikipedia.system.WikipediaFeed.WikipediaFeedEvent;

/**
 * This task is very simple. All it does is take messages that it receives, and
 * sends them to a Kafka topic called wikipedia-raw.
 */
public class WikipediaFeedStreamTask implements StreamTask, InitableTask {
  private static final SystemStream OUTPUT_STREAM = new SystemStream("kafka", "wikipedia-raw-multi");
  private static final Random RAND = new Random();

  //private transient KeyValueStore<String, Integer> store;

  @Override
  public void init(Context context) {
    TaskContext taskContext = context.getTaskContext();
    //store = (KeyValueStore<String, Integer>) taskContext.getStore("wikipedia-stats");
  }

  @Override
  public void process(IncomingMessageEnvelope envelope, MessageCollector collector, TaskCoordinator coordinator) {
    Map<String, Object> outgoingMap = WikipediaFeedEvent.toMap((WikipediaFeedEvent) envelope.getMessage());
    //store.put(((WikipediaFeedEvent) envelope.getMessage()).getRawEvent(), 1);
    collector.send(new OutgoingMessageEnvelope(OUTPUT_STREAM, Integer.toString(RAND.nextInt(10)), null, outgoingMap));
  }
}
